"""The tile cache in scripts/fetch_dem.py.

Terrain is static and Terrarium tiles are immutable, so a tile should be
downloaded once and then never again -- including for a different grid size, a
different domain, or a rerun after a failure. Network egress is not available
here, so the downloader is stubbed and what is asserted is how often it is
called.
"""

import io
import math
import sys
import types
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts import fetch_dem  # noqa: E402

from app.schemas import Bounds  # noqa: E402

# A single tile at low zoom keeps the stubbed range to one request.
ONE_TILE = Bounds(lat_min=37.75, lat_max=37.80, lon_min=-122.45, lon_max=-122.40)
ZOOM = 10
TILE_ELEVATION_M = 123.0


def _terrarium_png(metres: float) -> bytes:
    """Encode a flat tile the way the upstream bucket serves it."""
    value = metres + 32768.0
    red = int(value // 256)
    green = int(value - red * 256)
    blue = int(round((value - red * 256 - green) * 256)) % 256
    buffer = io.BytesIO()
    Image.new("RGB", (fetch_dem.TILE_SIZE, fetch_dem.TILE_SIZE), (red, green, blue)).save(
        buffer, format="PNG"
    )
    return buffer.getvalue()


class _Response:
    def __init__(self, content: bytes) -> None:
        self.content = content

    def raise_for_status(self) -> None:
        pass


@pytest.fixture
def downloads(monkeypatch):
    """Stub httpx and count how many tiles are actually fetched."""
    counter = {"count": 0}

    class _Client:
        def __init__(self, **kwargs):
            pass

        def get(self, url):
            counter["count"] += 1
            return _Response(_terrarium_png(TILE_ELEVATION_M))

        def close(self):
            pass

    module = types.ModuleType("httpx")
    module.Client = _Client
    monkeypatch.setitem(sys.modules, "httpx", module)
    return counter


def test_a_cold_cache_downloads_and_writes_through(tmp_path, downloads):
    tiles = tmp_path / "tiles"
    mosaic, _, _, _, _ = fetch_dem.fetch_mosaic(ONE_TILE, ZOOM, tiles)

    assert downloads["count"] == 1
    assert len(list(tiles.glob("*.npy"))) == 1
    # The Terrarium round trip is exact, not approximate.
    assert np.allclose(mosaic, TILE_ELEVATION_M)


def test_a_warm_cache_does_not_touch_the_network(tmp_path, downloads):
    tiles = tmp_path / "tiles"
    first, _, _, _, _ = fetch_dem.fetch_mosaic(ONE_TILE, ZOOM, tiles)
    downloads["count"] = 0

    second, _, _, _, _ = fetch_dem.fetch_mosaic(ONE_TILE, ZOOM, tiles)

    assert downloads["count"] == 0
    assert np.array_equal(first, second)


def test_only_the_missing_tiles_are_refetched(tmp_path, downloads):
    tiles = tmp_path / "tiles"
    expected, _, _, _, _ = fetch_dem.fetch_mosaic(ONE_TILE, ZOOM, tiles)
    next(iter(tiles.glob("*.npy"))).unlink()
    downloads["count"] = 0

    mosaic, _, _, _, _ = fetch_dem.fetch_mosaic(ONE_TILE, ZOOM, tiles)

    assert downloads["count"] == 1
    assert np.array_equal(mosaic, expected)


def test_a_corrupt_tile_is_refetched_not_trusted(tmp_path, downloads):
    tiles = tmp_path / "tiles"
    expected, _, _, _, _ = fetch_dem.fetch_mosaic(ONE_TILE, ZOOM, tiles)
    next(iter(tiles.glob("*.npy"))).write_bytes(b"not a numpy file")
    downloads["count"] = 0

    mosaic, _, _, _, _ = fetch_dem.fetch_mosaic(ONE_TILE, ZOOM, tiles)

    assert downloads["count"] == 1
    assert np.array_equal(mosaic, expected)


def test_the_tile_cache_can_be_bypassed(tmp_path, downloads):
    tiles = tmp_path / "tiles"
    fetch_dem.fetch_mosaic(ONE_TILE, ZOOM, tiles)
    downloads["count"] = 0

    fetch_dem.fetch_mosaic(ONE_TILE, ZOOM, None)

    assert downloads["count"] == 1
    # Bypassing must not disturb what is already cached.
    assert len(list(tiles.glob("*.npy"))) == 1


def test_a_cached_domain_serves_every_grid_size_without_network(tmp_path, downloads):
    """The point of the cache: a new grid size is a local resample.

    The DEM cache is keyed by (bounds, grid_x, grid_y), so each grid size is a
    separate entry. They must not each cost a fresh download.
    """
    tiles = tmp_path / "tiles"
    mosaic, x_origin, y_origin, _, _ = fetch_dem.fetch_mosaic(ONE_TILE, ZOOM, tiles)
    downloads["count"] = 0

    for grid_x, grid_y in ((64, 64), (128, 140), (200, 210)):
        grid = fetch_dem.resample(
            mosaic, x_origin, y_origin, ZOOM, ONE_TILE, grid_x, grid_y
        )
        assert grid.shape == (grid_y, grid_x)

    assert downloads["count"] == 0


def test_an_unwritable_configured_cache_dir_falls_back(monkeypatch, tmp_path):
    """`dem_cache_dir` defaults to the in-container path, which the host lacks."""
    monkeypatch.setattr(fetch_dem.settings, "dem_cache_dir", "/proc/nonexistent/dem")

    resolved = fetch_dem._resolve_cache_dir(None)

    assert resolved.is_dir()
    assert resolved != Path("/proc/nonexistent/dem")


def test_an_explicit_cache_dir_is_used_as_given(tmp_path):
    requested = tmp_path / "somewhere" / "else"

    assert fetch_dem._resolve_cache_dir(str(requested)) == requested
    assert requested.is_dir()


def test_tiles_are_stored_at_whole_tile_granularity(tmp_path, downloads):
    """Cache keys are z/x/y, so overlapping domains share tiles."""
    tiles = tmp_path / "tiles"
    fetch_dem.fetch_mosaic(ONE_TILE, ZOOM, tiles)

    tile_x = int(math.floor(fetch_dem.lon_to_tile_x(ONE_TILE.lon_min, ZOOM)))
    tile_y = int(math.floor(fetch_dem.lat_to_tile_y(ONE_TILE.lat_max, ZOOM)))
    assert fetch_dem._tile_cache_path(tiles, ZOOM, tile_x, tile_y).exists()

    # A shifted sub-domain landing on the same tile is free.
    downloads["count"] = 0
    shifted = Bounds(
        lat_min=ONE_TILE.lat_min + 0.005,
        lat_max=ONE_TILE.lat_max - 0.005,
        lon_min=ONE_TILE.lon_min + 0.005,
        lon_max=ONE_TILE.lon_max - 0.005,
    )
    fetch_dem.fetch_mosaic(shifted, ZOOM, tiles)
    assert downloads["count"] == 0
