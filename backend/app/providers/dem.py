"""Elevation grids, cached.

Terrain does not change, so fetching it over the network on every render is
pure waste -- and at fog resolution it is prohibitive: a 100 m grid over the
San Francisco domain is ~160,000 cells, which is 1,600 requests against the
Open-Meteo elevation endpoint at its 100-coordinate batch limit.

This module resolves an elevation grid in the cheapest available way:

1. an in-process memo, for repeated renders of the same viewport;
2. an on-disk ``.npy`` cache, which survives restarts;
3. a local DEM raster via rasterio, if one is configured;
4. the network, as a last resort -- and the result is then cached.

Grids use raster convention: row 0 is the NORTH edge (``lat_max``), matching
how an image is drawn. This is stated explicitly because it is the opposite of
``grid_builder.coordinate_lattice``, which is south-first.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Awaitable, Callable
import hashlib
import logging

import numpy as np

from app.schemas import Bounds

logger = logging.getLogger(__name__)

ElevationFetcher = Callable[[list[tuple[float, float]]], Awaitable[list[float]]]


def raster_coordinates(
    bounds: Bounds, grid_x: int, grid_y: int
) -> tuple[np.ndarray, np.ndarray]:
    """Return (latitudes, longitudes) 2-D arrays in north-first raster order."""
    latitudes = np.linspace(bounds.lat_max, bounds.lat_min, grid_y)
    longitudes = np.linspace(bounds.lon_min, bounds.lon_max, grid_x)
    return np.meshgrid(latitudes, longitudes, indexing="ij")


def cell_size_m(bounds: Bounds, grid_x: int, grid_y: int) -> tuple[float, float]:
    """Approximate north-south and east-west cell size in metres."""
    mean_lat = math_radians_mean(bounds)
    dy = (bounds.lat_max - bounds.lat_min) * 111_320.0 / max(grid_y - 1, 1)
    dx = (
        (bounds.lon_max - bounds.lon_min)
        * 111_320.0
        * np.cos(mean_lat)
        / max(grid_x - 1, 1)
    )
    return float(dy), float(dx)


def math_radians_mean(bounds: Bounds) -> float:
    return float(np.radians((bounds.lat_min + bounds.lat_max) / 2.0))


def _cache_key(bounds: Bounds, grid_x: int, grid_y: int) -> str:
    raw = (
        f"{bounds.lat_min:.6f},{bounds.lat_max:.6f},"
        f"{bounds.lon_min:.6f},{bounds.lon_max:.6f},{grid_x}x{grid_y}"
    )
    return hashlib.sha1(raw.encode()).hexdigest()[:20]


class DemProvider:
    """Resolves elevation grids from the cheapest available source."""

    def __init__(
        self,
        cache_dir: str | None = None,
        raster_path: str | None = None,
        fetcher: ElevationFetcher | None = None,
        max_memo_entries: int = 8,
    ) -> None:
        self.cache_dir = Path(cache_dir) if cache_dir else None
        self.raster_path = raster_path
        self.fetcher = fetcher
        self.max_memo_entries = max_memo_entries
        self._memo: dict[str, np.ndarray] = {}

    # ------------------------------------------------------------------

    async def elevation_grid(
        self, bounds: Bounds, grid_x: int, grid_y: int
    ) -> tuple[np.ndarray, str]:
        """Return a ``(grid_y, grid_x)`` elevation array and the source used."""
        key = _cache_key(bounds, grid_x, grid_y)

        memoized = self._memo.get(key)
        if memoized is not None:
            return memoized, "memo"

        cached = self._read_cache(key)
        if cached is not None and cached.shape == (grid_y, grid_x):
            self._memoize(key, cached)
            return cached, "disk-cache"

        raster = self._read_raster(bounds, grid_x, grid_y)
        if raster is not None:
            self._memoize(key, raster)
            self._write_cache(key, raster)
            return raster, "raster"

        if self.fetcher is None:
            raise RuntimeError(
                "No elevation source available: configure dem_raster_path or "
                "supply a network fetcher."
            )

        latitudes, longitudes = raster_coordinates(bounds, grid_x, grid_y)
        coordinates = [
            (float(lat), float(lon))
            for lat, lon in zip(latitudes.ravel(), longitudes.ravel())
        ]
        values = await self.fetcher(coordinates)
        if len(values) != grid_x * grid_y:
            raise ValueError(
                f"Elevation source returned {len(values)} values for "
                f"{grid_x * grid_y} coordinates"
            )
        elevation = np.asarray(values, dtype=np.float64).reshape(grid_y, grid_x)
        self._memoize(key, elevation)
        self._write_cache(key, elevation)
        return elevation, "network"

    # ------------------------------------------------------------------

    def _memoize(self, key: str, elevation: np.ndarray) -> None:
        if len(self._memo) >= self.max_memo_entries:
            self._memo.pop(next(iter(self._memo)))
        self._memo[key] = elevation

    def _cache_path(self, key: str) -> Path | None:
        if self.cache_dir is None:
            return None
        return self.cache_dir / f"dem-{key}.npy"

    def _read_cache(self, key: str) -> np.ndarray | None:
        path = self._cache_path(key)
        if path is None or not path.exists():
            return None
        try:
            return np.load(path)
        except (OSError, ValueError) as exc:
            logger.warning("Ignoring unreadable DEM cache %s: %s", path, exc)
            return None

    def _write_cache(self, key: str, elevation: np.ndarray) -> None:
        path = self._cache_path(key)
        if path is None:
            return
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            np.save(path, elevation)
        except OSError as exc:
            # A read-only container is not a reason to fail a render.
            logger.warning("Could not write DEM cache %s: %s", path, exc)

    def _read_raster(
        self, bounds: Bounds, grid_x: int, grid_y: int
    ) -> np.ndarray | None:
        """Sample a local north-up DEM GeoTIFF, if one is configured."""
        if not self.raster_path:
            return None
        try:
            import rasterio  # noqa: PLC0415 - optional dependency
        except ImportError:
            logger.warning(
                "dem_raster_path is set but rasterio is not installed; "
                "falling back to the network elevation source."
            )
            return None

        try:
            with rasterio.open(self.raster_path) as dataset:
                transform = dataset.transform
                if transform.b != 0 or transform.d != 0:
                    logger.warning(
                        "DEM raster %s is rotated; only north-up rasters are "
                        "supported.",
                        self.raster_path,
                    )
                    return None

                latitudes, longitudes = raster_coordinates(bounds, grid_x, grid_y)
                # North-up affine: x = a*col + c, y = e*row + f.
                cols = (longitudes - transform.c) / transform.a
                rows = (latitudes - transform.f) / transform.e
                cols = np.clip(np.round(cols).astype(int), 0, dataset.width - 1)
                rows = np.clip(np.round(rows).astype(int), 0, dataset.height - 1)

                row_min, row_max = int(rows.min()), int(rows.max())
                col_min, col_max = int(cols.min()), int(cols.max())
                window = rasterio.windows.Window(
                    col_off=col_min,
                    row_off=row_min,
                    width=col_max - col_min + 1,
                    height=row_max - row_min + 1,
                )
                band = dataset.read(1, window=window).astype(np.float64)
                elevation = band[rows - row_min, cols - col_min]

                nodata = dataset.nodata
                if nodata is not None:
                    # Ocean cells in GLO-90 are sea level, not missing terrain.
                    elevation = np.where(elevation == nodata, 0.0, elevation)
                return np.nan_to_num(elevation, nan=0.0)
        except Exception as exc:  # rasterio raises a wide range of errors
            logger.warning("Could not read DEM raster %s: %s", self.raster_path, exc)
            return None
