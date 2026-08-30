import numpy as np
import pytest

from app.features.terrain import (
    aspect_radians,
    elevation_penalized_distance,
    ridge_mask,
    slope_radians,
    terrain_ruggedness,
)
from app.providers.dem import DemProvider, cell_size_m, raster_coordinates
from app.schemas import Bounds

BOUNDS = Bounds(lat_min=37.44, lat_max=37.95, lon_min=-122.65, lon_max=-122.15)


# ----------------------------------------------------------------------
# DEM provider
# ----------------------------------------------------------------------


class CountingFetcher:
    def __init__(self):
        self.calls = 0

    async def __call__(self, coordinates):
        self.calls += 1
        return [100.0 * index for index in range(len(coordinates))]


@pytest.mark.asyncio
async def test_elevation_grid_is_fetched_once_then_memoized(tmp_path):
    fetcher = CountingFetcher()
    provider = DemProvider(cache_dir=str(tmp_path), fetcher=fetcher)

    first, first_source = await provider.elevation_grid(BOUNDS, 8, 6)
    second, second_source = await provider.elevation_grid(BOUNDS, 8, 6)

    assert first.shape == (6, 8)
    assert first_source == "network"
    assert second_source == "memo"
    assert fetcher.calls == 1
    np.testing.assert_array_equal(first, second)


@pytest.mark.asyncio
async def test_the_disk_cache_survives_a_new_provider(tmp_path):
    fetcher = CountingFetcher()
    await DemProvider(cache_dir=str(tmp_path), fetcher=fetcher).elevation_grid(
        BOUNDS, 8, 6
    )

    fresh_fetcher = CountingFetcher()
    grid, source = await DemProvider(
        cache_dir=str(tmp_path), fetcher=fresh_fetcher
    ).elevation_grid(BOUNDS, 8, 6)

    assert source == "disk-cache"
    assert fresh_fetcher.calls == 0
    assert grid.shape == (6, 8)


@pytest.mark.asyncio
async def test_a_different_grid_size_is_a_different_cache_entry(tmp_path):
    fetcher = CountingFetcher()
    provider = DemProvider(cache_dir=str(tmp_path), fetcher=fetcher)

    await provider.elevation_grid(BOUNDS, 8, 6)
    await provider.elevation_grid(BOUNDS, 16, 12)

    assert fetcher.calls == 2


@pytest.mark.asyncio
async def test_no_source_at_all_is_an_explicit_error():
    provider = DemProvider(cache_dir=None, fetcher=None)
    with pytest.raises(RuntimeError, match="No elevation source"):
        await provider.elevation_grid(BOUNDS, 8, 6)


@pytest.mark.asyncio
async def test_a_short_response_is_rejected(tmp_path):
    async def short(coordinates):
        return [0.0]

    provider = DemProvider(cache_dir=str(tmp_path), fetcher=short)
    with pytest.raises(ValueError, match="returned 1 values"):
        await provider.elevation_grid(BOUNDS, 8, 6)


def test_raster_coordinates_run_north_to_south():
    latitudes, longitudes = raster_coordinates(BOUNDS, 4, 3)

    assert latitudes.shape == (3, 4)
    # Row 0 is the north edge.
    assert latitudes[0, 0] == BOUNDS.lat_max
    assert latitudes[-1, 0] == BOUNDS.lat_min
    # Columns run west to east.
    assert longitudes[0, 0] == BOUNDS.lon_min
    assert longitudes[0, -1] == BOUNDS.lon_max


def test_cell_size_is_metres_and_shrinks_with_latitude():
    dy, dx = cell_size_m(BOUNDS, 420, 420)
    assert 100 < dy < 160
    assert 90 < dx < 140
    # Longitude degrees are shorter than latitude degrees at 37.7 N.
    assert dx < dy


# ----------------------------------------------------------------------
# Terrain features
# ----------------------------------------------------------------------


def test_slope_of_a_flat_plane_is_zero():
    assert np.allclose(slope_radians(np.zeros((5, 5)), 100.0, 100.0), 0.0)


def test_slope_of_a_known_ramp():
    # Rises 100 m over 100 m eastward: a 45 degree slope.
    elevation = np.tile(np.arange(5) * 100.0, (5, 1))
    slope = slope_radians(elevation, cell_dy_m=100.0, cell_dx_m=100.0)
    assert slope[2, 2] == pytest.approx(np.pi / 4)


def test_aspect_of_a_west_facing_slope():
    # Elevation increases eastward, so the downhill direction is west (270 deg),
    # which is the face the marine layer arrives on.
    elevation = np.tile(np.arange(5) * 100.0, (5, 1))
    aspect = aspect_radians(elevation, cell_dy_m=100.0, cell_dx_m=100.0)
    assert np.degrees(aspect[2, 2]) == pytest.approx(270.0)


def test_aspect_of_a_south_facing_slope():
    # Row 0 is north, so elevation increasing with row index means the ground
    # falls away to the north (0 degrees).
    elevation = np.tile((np.arange(5) * 100.0)[:, None], (1, 5))
    aspect = aspect_radians(elevation, cell_dy_m=100.0, cell_dx_m=100.0)
    assert np.degrees(aspect[2, 2]) == pytest.approx(0.0)


def test_ruggedness_is_zero_on_the_flat_and_positive_on_a_ridge():
    flat = np.full((5, 5), 42.0)
    assert np.allclose(terrain_ruggedness(flat), 0.0)

    ridge = np.zeros((5, 5))
    ridge[:, 2] = 300.0
    assert terrain_ruggedness(ridge)[2, 2] > 100.0


def test_ridge_mask_selects_terrain_above_the_fog_top():
    elevation = np.array([[10.0, 281.0, 784.0]])
    mask = ridge_mask(elevation, above_m=240.0)
    assert list(mask[0]) == [False, True, True]


# ----------------------------------------------------------------------
# The metric this project replaced, kept as a documented regression.
# ----------------------------------------------------------------------


def test_elevation_penalised_distance_leaks_across_a_ridge():
    """Why fog needs cost distance instead of this.

    Predicting at the Mission: the Sunset is 2.3x further away and sits behind
    the 281 m Twin Peaks ridge, yet this metric scores it as *closer* than the
    summit station in direct line of sight, so a fogged Sunset observation
    dominates a clear Mission cell.
    """
    mission = (37.7590, -122.4150, 20.0)
    sunset = (37.7550, -122.4900, 15.0)
    twin_peaks = (37.7544, -122.4477, 281.0)

    sunset_distance = elevation_penalized_distance(
        *sunset, *mission, elevation_weight=0.62
    )
    summit_distance = elevation_penalized_distance(
        *twin_peaks, *mission, elevation_weight=0.62
    )

    assert sunset_distance < summit_distance
    # Under the default IDW power the far, blocked station wins by half again.
    weight_ratio = (summit_distance / sunset_distance) ** 2.4
    assert weight_ratio == pytest.approx(1.53, abs=0.02)
