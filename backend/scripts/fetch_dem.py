#!/usr/bin/env python3
"""Populate the DEM cache from AWS Terrain Tiles.

Downloads Terrarium-encoded elevation tiles from the public
``elevation-tiles-prod`` bucket (free, no key), resamples them onto the model
grid, and writes the result into the same on-disk cache
``providers.dem.DemProvider`` reads. After running this the API never touches
the Open-Meteo elevation endpoint for that viewport.

The same tiles back the 3D terrain in the web client, so the surface the fog is
cut against and the surface you see are the identical dataset.

    python -m scripts.fetch_dem --grid 420x420
    python -m scripts.fetch_dem --bounds 37.44,37.95,-122.65,-122.15 --zoom 12

Terrarium encoding: ``elevation_m = R * 256 + G + B / 256 - 32768``.
"""

from __future__ import annotations

import argparse
import io
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.config import settings  # noqa: E402
from app.providers.dem import _cache_key, raster_coordinates  # noqa: E402
from app.schemas import Bounds  # noqa: E402

TILE_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
TILE_SIZE = 256


def lon_to_tile_x(longitude: float, zoom: int) -> float:
    return (longitude + 180.0) / 360.0 * (2**zoom)


def lat_to_tile_y(latitude: float, zoom: int) -> float:
    radians = math.radians(latitude)
    return (
        (1.0 - math.asinh(math.tan(radians)) / math.pi) / 2.0 * (2**zoom)
    )


def fetch_mosaic(bounds: Bounds, zoom: int) -> tuple[np.ndarray, float, float, float, float]:
    """Download every tile covering the bounds and stitch them into one array.

    Returns the mosaic plus the fractional tile coordinates of its top-left
    corner, so callers can map lat/lon onto pixel positions.
    """
    import httpx
    from PIL import Image

    x_min = int(math.floor(lon_to_tile_x(bounds.lon_min, zoom)))
    x_max = int(math.floor(lon_to_tile_x(bounds.lon_max, zoom)))
    y_min = int(math.floor(lat_to_tile_y(bounds.lat_max, zoom)))
    y_max = int(math.floor(lat_to_tile_y(bounds.lat_min, zoom)))

    columns = x_max - x_min + 1
    rows = y_max - y_min + 1
    total = columns * rows
    print(f"Fetching {total} tile(s) at zoom {zoom} "
          f"(x {x_min}-{x_max}, y {y_min}-{y_max})")

    mosaic = np.zeros((rows * TILE_SIZE, columns * TILE_SIZE), dtype=np.float64)
    with httpx.Client(timeout=60.0, follow_redirects=True) as client:
        for row, tile_y in enumerate(range(y_min, y_max + 1)):
            for column, tile_x in enumerate(range(x_min, x_max + 1)):
                url = TILE_URL.format(z=zoom, x=tile_x, y=tile_y)
                response = client.get(url)
                response.raise_for_status()
                image = Image.open(io.BytesIO(response.content)).convert("RGB")
                pixels = np.asarray(image, dtype=np.float64)
                elevation = (
                    pixels[:, :, 0] * 256.0
                    + pixels[:, :, 1]
                    + pixels[:, :, 2] / 256.0
                    - 32768.0
                )
                mosaic[
                    row * TILE_SIZE : (row + 1) * TILE_SIZE,
                    column * TILE_SIZE : (column + 1) * TILE_SIZE,
                ] = elevation
        print(f"  fetched {total}/{total}")

    return mosaic, float(x_min), float(y_min), float(zoom), float(TILE_SIZE)


def resample(
    mosaic: np.ndarray,
    tile_x_origin: float,
    tile_y_origin: float,
    zoom: int,
    bounds: Bounds,
    grid_x: int,
    grid_y: int,
) -> np.ndarray:
    """Max-pool the mosaic onto the north-first model grid.

    Downsampling by *maximum* rather than by nearest neighbour or mean is the
    right choice for a barrier model: what decides whether fog crosses a ridge
    is the highest ground in the cell, and a one-pixel-wide crest averaged away
    is a wall the model would let fog walk straight through. Nearest-neighbour
    sampling at 110 m cells reads Twin Peaks about 17 m low and Mount Tam about
    48 m low, which is enough to change the answer at a realistic fog top.

    Cells that no source pixel lands in -- possible if the output grid is finer
    than the tiles -- fall back to nearest neighbour.
    """
    latitudes, longitudes = raster_coordinates(bounds, grid_x, grid_y)

    # Forward-map every source pixel into an output cell, then take the max.
    source_rows, source_columns = np.indices(mosaic.shape)
    source_tile_x = tile_x_origin + (source_columns + 0.5) / TILE_SIZE
    source_tile_y = tile_y_origin + (source_rows + 0.5) / TILE_SIZE
    source_lon = source_tile_x / (2**zoom) * 360.0 - 180.0
    source_lat = np.degrees(
        np.arctan(np.sinh(np.pi * (1.0 - 2.0 * source_tile_y / (2**zoom))))
    )

    lat_span = bounds.lat_max - bounds.lat_min
    lon_span = bounds.lon_max - bounds.lon_min
    target_row = np.round((bounds.lat_max - source_lat) / lat_span * (grid_y - 1))
    target_column = np.round((source_lon - bounds.lon_min) / lon_span * (grid_x - 1))

    inside = (
        (target_row >= 0)
        & (target_row <= grid_y - 1)
        & (target_column >= 0)
        & (target_column <= grid_x - 1)
    )

    pooled = np.full((grid_y, grid_x), -np.inf)
    np.maximum.at(
        pooled,
        (target_row[inside].astype(int), target_column[inside].astype(int)),
        mosaic[inside],
    )

    # Fall back to nearest neighbour wherever nothing landed.
    empty = ~np.isfinite(pooled)
    if empty.any():
        pixel_x = (lon_to_tile_x_array(longitudes, zoom) - tile_x_origin) * TILE_SIZE
        pixel_y = (lat_to_tile_y_array(latitudes, zoom) - tile_y_origin) * TILE_SIZE
        columns = np.clip(np.round(pixel_x).astype(int), 0, mosaic.shape[1] - 1)
        rows = np.clip(np.round(pixel_y).astype(int), 0, mosaic.shape[0] - 1)
        pooled[empty] = mosaic[rows[empty], columns[empty]]
        print(f"  {int(empty.sum())} cell(s) fell back to nearest neighbour")

    # Terrarium encodes bathymetry as negative elevation. The sea surface is at
    # sea level, and fog sits on top of it, so the ocean floor is not terrain
    # the marine layer has to climb.
    return np.maximum(pooled, 0.0)


def lon_to_tile_x_array(longitudes: np.ndarray, zoom: int) -> np.ndarray:
    return (longitudes + 180.0) / 360.0 * (2**zoom)


def lat_to_tile_y_array(latitudes: np.ndarray, zoom: int) -> np.ndarray:
    radians = np.radians(latitudes)
    return (1.0 - np.arcsinh(np.tan(radians)) / np.pi) / 2.0 * (2**zoom)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--bounds",
        help="lat_min,lat_max,lon_min,lon_max (defaults to the configured fog domain)",
    )
    parser.add_argument(
        "--grid",
        default="160x176,256x280,340x372,420x420",
        help=(
            "comma-separated grid_x by grid_y, e.g. 256x280,420x420. The cache "
            "is keyed by grid size, so fetch every resolution the client offers."
        ),
    )
    parser.add_argument(
        "--zoom",
        type=int,
        default=12,
        help="tile zoom; 12 is ~30 m per pixel at this latitude",
    )
    parser.add_argument("--cache-dir", default=None, help="defaults to dem_cache_dir")
    arguments = parser.parse_args()

    if arguments.bounds:
        lat_min, lat_max, lon_min, lon_max = (
            float(part) for part in arguments.bounds.split(",")
        )
        bounds = Bounds(
            lat_min=lat_min, lat_max=lat_max, lon_min=lon_min, lon_max=lon_max
        )
    else:
        bounds = Bounds(
            lat_min=settings.fog_bounds_lat_min,
            lat_max=settings.fog_bounds_lat_max,
            lon_min=settings.fog_bounds_lon_min,
            lon_max=settings.fog_bounds_lon_max,
        )

    grids = []
    for spec in arguments.grid.split(","):
        grid_x, _, grid_y = spec.strip().partition("x")
        grids.append((int(grid_x), int(grid_y)))

    # The tiles are the expensive part, so download once and resample per grid.
    mosaic, tile_x_origin, tile_y_origin, _, _ = fetch_mosaic(bounds, arguments.zoom)

    cache_dir = Path(arguments.cache_dir or settings.dem_cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)

    for grid_x, grid_y in grids:
        elevation = resample(
            mosaic, tile_x_origin, tile_y_origin, arguments.zoom, bounds, grid_x, grid_y
        )
        path = cache_dir / f"dem-{_cache_key(bounds, grid_x, grid_y)}.npy"
        np.save(path, elevation)
        print(
            f"Wrote {path}  ({grid_y}x{grid_x}, "
            f"{elevation.min():.0f}-{elevation.max():.0f} m)"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
