import numpy as np
import pytest

from app.services.cost_distance import (
    build_cost_graph,
    cell_index,
    cost_distances,
    geographic_distances,
    inverse_distance_weighted,
)
from tests.terrain_fixtures import PENINSULA_BOUNDS, peninsula

N_ROWS, N_COLS = 60, 80
CELL_M = 100.0

# A row well south of the gap, so anything crossing here has to detour north.
SOUTH_ROW = 40
WEST_COL = 12
JUST_WEST_COL = 33
JUST_EAST_COL = 47
RIDGE_COL = 40


def _flat(row: int, col: int) -> int:
    return row * N_COLS + col


def _distances(fog_top_m: float, beta: float = 12.0) -> np.ndarray:
    elevation = peninsula(N_ROWS, N_COLS)
    graph = build_cost_graph(
        elevation,
        cell_dy_m=CELL_M,
        cell_dx_m=CELL_M,
        fog_top_m=fog_top_m,
        beta=beta,
        scale_m=60.0,
        block_buffer_m=25.0,
    )
    return cost_distances(graph, [_flat(SOUTH_ROW, WEST_COL)])[0]


def test_a_ridge_above_the_inversion_blocks_the_crossing():
    distances = _distances(fog_top_m=240.0)

    west = distances[_flat(SOUTH_ROW, JUST_WEST_COL)]
    east = distances[_flat(SOUTH_ROW, JUST_EAST_COL)]

    assert np.isfinite(west)
    # Reaching the east side means going north to the gap and back down.
    assert east > 3 * west


def test_the_detour_is_terrain_not_geometry():
    """The two target cells are almost equidistant in a straight line."""
    latitudes = np.linspace(
        PENINSULA_BOUNDS.lat_max, PENINSULA_BOUNDS.lat_min, N_ROWS
    )
    longitudes = np.linspace(
        PENINSULA_BOUNDS.lon_min, PENINSULA_BOUNDS.lon_max, N_COLS
    )
    lat_grid, lon_grid = np.meshgrid(latitudes, longitudes, indexing="ij")

    straight = geographic_distances(
        lat_grid,
        lon_grid,
        [float(latitudes[SOUTH_ROW])],
        [float(longitudes[WEST_COL])],
    )[0]

    west = straight[_flat(SOUTH_ROW, JUST_WEST_COL)]
    east = straight[_flat(SOUTH_ROW, JUST_EAST_COL)]
    # Straight-line distance says these are comparable...
    assert east / west < 1.8

    # ...but cost distance, which is the point of this module, does not.
    cost = _distances(fog_top_m=240.0)
    assert cost[_flat(SOUTH_ROW, JUST_EAST_COL)] / cost[
        _flat(SOUTH_ROW, JUST_WEST_COL)
    ] > 3


def test_terrain_above_the_inversion_is_unreachable():
    distances = _distances(fog_top_m=240.0)
    # The crest is at 300 m, well past the 240 m top plus its 25 m buffer.
    assert not np.isfinite(distances[_flat(SOUTH_ROW, RIDGE_COL)])


def test_raising_the_fog_top_over_the_crest_opens_the_ridge():
    blocked = _distances(fog_top_m=240.0)
    overtopping = _distances(fog_top_m=400.0)

    east = _flat(SOUTH_ROW, JUST_EAST_COL)
    assert overtopping[east] < 0.6 * blocked[east]
    # And the crest itself is now inside the layer.
    assert np.isfinite(overtopping[_flat(SOUTH_ROW, RIDGE_COL)])


def test_beta_zero_still_blocks_but_does_not_penalise_climbing():
    penalised = _distances(fog_top_m=240.0, beta=12.0)
    unpenalised = _distances(fog_top_m=240.0, beta=0.0)
    east = _flat(SOUTH_ROW, JUST_EAST_COL)
    # Both must detour through the gap; the penalised one costs more.
    assert np.isfinite(unpenalised[east])
    assert penalised[east] >= unpenalised[east]


def test_idw_gives_unreachable_cells_no_influence():
    distances = np.array([[10.0, np.inf, 40.0]])
    values = np.array([1.0])
    interpolated, reachable = inverse_distance_weighted(distances, values, power=2.0)

    assert interpolated[0] == pytest.approx(1.0)
    assert interpolated[1] == 0.0
    assert list(reachable) == [True, False, True]


def test_idw_blends_two_stations_by_inverse_square():
    distances = np.array([[100.0, 100.0], [100.0, 300.0]])
    values = np.array([1.0, 0.0])
    interpolated, _ = inverse_distance_weighted(distances, values, power=2.0)

    # Equidistant: straight average.
    assert interpolated[0] == pytest.approx(0.5)
    # Three times closer to the fogged station, so nine times the weight.
    assert interpolated[1] == pytest.approx(0.9)


def test_cell_index_uses_north_first_raster_order():
    bounds = PENINSULA_BOUNDS
    north_west = cell_index(bounds, 80, 60, bounds.lat_max, bounds.lon_min)
    south_east = cell_index(bounds, 80, 60, bounds.lat_min, bounds.lon_max)

    assert north_west == 0
    assert south_east == 80 * 60 - 1


def test_cell_index_rejects_points_outside_the_domain():
    bounds = PENINSULA_BOUNDS
    assert cell_index(bounds, 80, 60, 38.5, -122.4) is None
    assert cell_index(bounds, 80, 60, 37.7, -121.0) is None


def test_graph_requires_a_two_dimensional_grid():
    with pytest.raises(ValueError):
        build_cost_graph(np.zeros(10), 100.0, 100.0, fog_top_m=200.0)
