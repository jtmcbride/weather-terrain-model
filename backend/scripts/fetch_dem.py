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
# Decoded tiles live here, one file per z/x/y. Terrain is static and tiles are
# immutable, so this is written once and then never refetched -- including for
# a different grid size, a different domain, or a rerun after a failure.
TILE_CACHE_SUBDIR = "tiles"


def lon_to_tile_x(longitude: float, zoom: int) -> float:
    return (longitude + 180.0) / 360.0 * (2**zoom)


def lat_to_tile_y(latitude: float, zoom: int) -> float:
    radians = math.radians(latitude)
    return (
        (1.0 - math.asinh(math.tan(radians)) / math.pi) / 2.0 * (2**zoom)
    )


def _tile_cache_path(tile_cache_dir: Path, zoom: int, tile_x: int, tile_y: int) -> Path:
    return tile_cache_dir / f"terrarium-z{zoom}-x{tile_x}-y{tile_y}.npy"


def _read_cached_tile(
    tile_cache_dir: Path | None, zoom: int, tile_x: int, tile_y: int
) -> np.ndarray | None:
    if tile_cache_dir is None:
        return None
    path = _tile_cache_path(tile_cache_dir, zoom, tile_x, tile_y)
    if not path.exists():
        return None
    try:
        tile = np.load(path)
    except (OSError, ValueError) as exc:
        print(f"  ignoring unreadable tile {path.name}: {exc}")
        return None
    if tile.shape != (TILE_SIZE, TILE_SIZE):
        print(f"  ignoring malformed tile {path.name}: shape {tile.shape}")
        return None
    return tile.astype(np.float64)


def _write_cached_tile(
    tile_cache_dir: Path | None,
    zoom: int,
    tile_x: int,
    tile_y: int,
    tile: np.ndarray,
) -> None:
    if tile_cache_dir is None:
        return
    path = _tile_cache_path(tile_cache_dir, zoom, tile_x, tile_y)
    try:
        tile_cache_dir.mkdir(parents=True, exist_ok=True)
        # Terrarium resolves to 1/256 m, which float32 holds exactly at these
        # magnitudes, and halves the cache against float64.
        np.save(path, tile.astype(np.float32))
    except OSError as exc:
        # A read-only cache is a slow prefetch, not a failed one.
        print(f"  could not cache tile {path.name}: {exc}")


def _decode_terrarium(content: bytes) -> np.ndarray:
    """Terrarium PNG to metres: elevation = R * 256 + G + B / 256 - 32768."""
    from PIL import Image  # noqa: PLC0415 - only needed when actually downloading

    image = Image.open(io.BytesIO(content)).convert("RGB")
    pixels = np.asarray(image, dtype=np.float64)
    return (
        pixels[:, :, 0] * 256.0
        + pixels[:, :, 1]
        + pixels[:, :, 2] / 256.0
        - 32768.0
    )


def fetch_mosaic(
    bounds: Bounds, zoom: int, tile_cache_dir: Path | None = None
) -> tuple[np.ndarray, float, float, float, float]:
    """Assemble every tile covering the bounds into one array.

    Tiles come from the on-disk cache when they are there and from the network
    when they are not, and anything downloaded is cached on the way through. A
    fully cached mosaic needs no network and no Pillow at all, which is what
    makes a second grid size, a shifted domain, or a resumed run free.

    Returns the mosaic plus the fractional tile coordinates of its top-left
    corner, so callers can map lat/lon onto pixel positions.
    """
    x_min = int(math.floor(lon_to_tile_x(bounds.lon_min, zoom)))
    x_max = int(math.floor(lon_to_tile_x(bounds.lon_max, zoom)))
    y_min = int(math.floor(lat_to_tile_y(bounds.lat_max, zoom)))
    y_max = int(math.floor(lat_to_tile_y(bounds.lat_min, zoom)))

    columns = x_max - x_min + 1
    rows = y_max - y_min + 1
    total = columns * rows
    print(f"Assembling {total} tile(s) at zoom {zoom} "
          f"(x {x_min}-{x_max}, y {y_min}-{y_max})")

    mosaic = np.zeros((rows * TILE_SIZE, columns * TILE_SIZE), dtype=np.float64)
    client = None
    reused = 0
    downloaded = 0
    try:
        for row, tile_y in enumerate(range(y_min, y_max + 1)):
            for column, tile_x in enumerate(range(x_min, x_max + 1)):
                tile = _read_cached_tile(tile_cache_dir, zoom, tile_x, tile_y)
                if tile is None:
                    if client is None:
                        import httpx  # noqa: PLC0415 - only needed to download

                        client = httpx.Client(timeout=60.0, follow_redirects=True)
                    response = client.get(
                        TILE_URL.format(z=zoom, x=tile_x, y=tile_y)
                    )
                    response.raise_for_status()
                    tile = _decode_terrarium(response.content)
                    _write_cached_tile(tile_cache_dir, zoom, tile_x, tile_y, tile)
                    downloaded += 1
                    if downloaded % 20 == 0:
                        print(f"  downloaded {downloaded} tile(s)")
                else:
                    reused += 1
                mosaic[
                    row * TILE_SIZE : (row + 1) * TILE_SIZE,
                    column * TILE_SIZE : (column + 1) * TILE_SIZE,
                ] = tile
    finally:
        if client is not None:
            client.close()

    print(f"  {reused} tile(s) from cache, {downloaded} downloaded")
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


def _resolve_cache_dir(requested: str | None) -> Path:
    """Where the resampled grids are written.

    ``settings.dem_cache_dir`` defaults to ``/app/.dem-cache``, which is the
    path *inside the API container*. Running this script on the host cannot
    create it, so an unwritable configured default falls back to the repo-local
    directory that Compose bind-mounts into the container. An explicitly
    requested directory is never second-guessed.
    """
    if requested:
        path = Path(requested)
        path.mkdir(parents=True, exist_ok=True)
        return path

    configured = Path(settings.dem_cache_dir)
    try:
        configured.mkdir(parents=True, exist_ok=True)
        return configured
    except OSError:
        fallback = Path(__file__).resolve().parents[1] / ".dem-cache"
        fallback.mkdir(parents=True, exist_ok=True)
        print(
            f"{configured} is not writable here (it is the in-container path); "
            f"writing to {fallback} instead."
        )
        return fallback


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
    parser.add_argument(
        "--tile-cache-dir",
        default=None,
        help=(
            f"where decoded elevation tiles are kept (defaults to "
            f"<cache-dir>/{TILE_CACHE_SUBDIR}). Tiles are immutable, so this is "
            "populated once and reused by every later grid size and domain."
        ),
    )
    parser.add_argument(
        "--no-tile-cache",
        action="store_true",
        help="download tiles without reading or writing the tile cache",
    )
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

    cache_dir = _resolve_cache_dir(arguments.cache_dir)
    tile_cache_dir: Path | None = None
    if not arguments.no_tile_cache:
        tile_cache_dir = (
            Path(arguments.tile_cache_dir)
            if arguments.tile_cache_dir
            else cache_dir / TILE_CACHE_SUBDIR
        )

    # The tiles are the expensive part, so fetch once and resample per grid.
    mosaic, tile_x_origin, tile_y_origin, _, _ = fetch_mosaic(
        bounds, arguments.zoom, tile_cache_dir
    )

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
