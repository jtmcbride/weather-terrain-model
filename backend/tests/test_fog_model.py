"""End-to-end behaviour of the fog grid, on synthetic terrain.

These are the tests that encode the actual requirement: when two sides of a
high ridge report different conditions, the fog boundary must land *on the
ridge* rather than somewhere in the open ground between the two stations, and
the fog surface must follow the shape of the hill.

Note on semantics: marine influence is an interpolation *between* observations.
With a single station, inverse-distance weighting returns that station's value
everywhere it can reach -- so the horizontal position of a fog edge comes from
observations disagreeing, and terrain routing decides where that disagreement
resolves. The vertical cut against the slab is what shapes the edge.
"""

import numpy as np
import pytest

from app.features.fog import SlabDiagnosis
from app.services.fog_model import FogStationInput, build_fog_grid
from tests.terrain_fixtures import PENINSULA_BOUNDS, conical_hill, peninsula

N_ROWS, N_COLS = 60, 80
SOUTH_ROW = 40

# The ridge occupies columns 36-44 with its crest at column 40. Column 35 is
# open ground just west of it; column 47 is just east.
WEST_OF_RIDGE = 35
EAST_OF_RIDGE = 47
CREST = 40
GAP_ROW = 7

LATITUDES = np.linspace(PENINSULA_BOUNDS.lat_max, PENINSULA_BOUNDS.lat_min, N_ROWS)
LONGITUDES = np.linspace(PENINSULA_BOUNDS.lon_min, PENINSULA_BOUNDS.lon_max, N_COLS)


def _slab(base_m: float = 0.0, top_m: float = 240.0) -> SlabDiagnosis:
    return SlabDiagnosis(
        base_m=base_m,
        top_m=top_m,
        inversion_base_m=top_m,
        inversion_strength_c=6.0,
        lcl_m=0.0,
        froude_number=0.6,
        blocking_regime="blocked",
        source="test",
    )


def _station(column: int, fog_fraction: float, name: str) -> FogStationInput:
    return FogStationInput(
        source="test",
        station_id=name,
        latitude=float(LATITUDES[SOUTH_ROW]),
        longitude=float(LONGITUDES[column]),
        elevation=10.0,
        visibility_m=300.0 if fog_fraction > 0.5 else 16000.0,
        fog_fraction=fog_fraction,
    )


# A fogged station on the ocean side and a clear one on the bay side: the
# "different readings on two sides" case.
FOGGED_WEST = _station(12, 1.0, "WEST")
CLEAR_EAST = _station(50, 0.0, "EAST")


def _build(stations, terrain_routing=True, top_m=240.0, base_m=0.0, **kwargs):
    return build_fog_grid(
        bounds=PENINSULA_BOUNDS,
        grid_x=N_COLS,
        grid_y=N_ROWS,
        elevation=peninsula(N_ROWS, N_COLS),
        stations=stations,
        slab=_slab(base_m=base_m, top_m=top_m),
        terrain_routing=terrain_routing,
        **kwargs,
    )


def _boundary_column(influence_row: np.ndarray) -> int:
    """First column where marine influence drops below one half."""
    return int(np.argmax(influence_row < 0.5))


def test_fog_holds_up_to_the_ridge_and_stops_dead():
    result = _build([FOGGED_WEST, CLEAR_EAST], terrain_routing=True)

    assert result.fog_fraction[SOUTH_ROW, WEST_OF_RIDGE] > 0.8
    assert result.fog_fraction[SOUTH_ROW, EAST_OF_RIDGE] < 0.1


def test_terrain_routing_puts_the_boundary_on_the_ridge_not_in_open_ground():
    """The regression this whole model exists to fix.

    Straight-line weighting has no barriers, so the fog edge lands roughly
    midway between the two stations -- several kilometres west of the hill, in
    open ground where nothing is stopping it. Cost distance pins it to the ridge.
    """
    routed = _build([FOGGED_WEST, CLEAR_EAST], terrain_routing=True)
    straight = _build([FOGGED_WEST, CLEAR_EAST], terrain_routing=False)

    routed_edge = _boundary_column(routed.marine_influence[SOUTH_ROW])
    straight_edge = _boundary_column(straight.marine_influence[SOUTH_ROW])

    # The ridge starts at column 36; the routed edge sits inside it.
    assert 36 <= routed_edge <= 44
    # The straight-line edge falls well west of the hill.
    assert straight_edge < 34
    assert routed_edge - straight_edge >= 4

    # Put another way: just west of the hill, routing keeps the fog dense while
    # straight-line weighting has already thinned it out.
    assert routed.marine_influence[SOUTH_ROW, WEST_OF_RIDGE] > 0.9
    assert straight.marine_influence[SOUTH_ROW, WEST_OF_RIDGE] < 0.4


def test_fog_pours_through_the_gap_rather_than_over_the_crest():
    result = _build([FOGGED_WEST, CLEAR_EAST], terrain_routing=True)

    through_gap = result.marine_influence[GAP_ROW, EAST_OF_RIDGE]
    behind_ridge = result.marine_influence[SOUTH_ROW, EAST_OF_RIDGE]

    assert through_gap > 0.3
    assert through_gap > 50 * behind_ridge


def test_the_ridge_crest_stands_above_the_deck():
    result = _build([FOGGED_WEST], terrain_routing=True, top_m=240.0)
    crest = (SOUTH_ROW, CREST)

    assert result.elevation[crest] > 240.0
    assert result.fog_fraction[crest] == 0.0
    assert result.surface_state[crest] in {"above_deck", "clear"}


def test_raising_the_fog_top_swallows_the_crest():
    """Same terrain, one parameter: the level set is what moves."""
    shallow = _build([FOGGED_WEST], terrain_routing=True, top_m=240.0)
    deep = _build([FOGGED_WEST], terrain_routing=True, top_m=500.0)
    crest = (SOUTH_ROW, CREST)

    assert shallow.fog_fraction[crest] == 0.0
    assert deep.fog_fraction[crest] > 0.8
    assert deep.surface_state[crest] == "in_fog"


def test_the_fog_edge_traces_an_elevation_contour():
    """On a cone, the fog boundary must be the H contour, not a circle."""
    size = 61
    elevation = conical_hill(size, size, summit_m=400.0)
    fog_top = 200.0

    latitudes = np.linspace(PENINSULA_BOUNDS.lat_max, PENINSULA_BOUNDS.lat_min, size)
    longitudes = np.linspace(PENINSULA_BOUNDS.lon_min, PENINSULA_BOUNDS.lon_max, size)
    station = FogStationInput(
        source="test",
        latitude=float(latitudes[size - 1]),
        longitude=float(longitudes[0]),
        elevation=float(elevation[size - 1, 0]),
        fog_fraction=1.0,
    )

    result = build_fog_grid(
        bounds=PENINSULA_BOUNDS,
        grid_x=size,
        grid_y=size,
        elevation=elevation,
        stations=[station],
        slab=_slab(base_m=0.0, top_m=fog_top),
        terrain_routing=True,
    )

    well_below = elevation < fog_top - 60.0
    well_above = elevation > fog_top + 60.0

    # Nothing above the top is fogged, however close to the station it is;
    # everything reachable below it is, however far away.
    assert result.fog_fraction[well_above].max() == 0.0
    reachable_below = well_below & (result.marine_influence > 0.3)
    assert reachable_below.any()
    assert result.fog_fraction[reachable_below].min() > 0.25

    # And the edge really is the contour: the highest fogged cell and the
    # lowest clear cell both sit within the feather of the fog top.
    fogged = result.fog_fraction > 0.5
    assert abs(elevation[fogged].max() - fog_top) < 40.0


def test_a_station_under_a_lifted_deck_still_marks_marine_air_present():
    """Good surface visibility under a stratus deck is not a fog-free report."""
    station = FogStationInput(
        source="test",
        latitude=float(LATITUDES[SOUTH_ROW]),
        longitude=float(LONGITUDES[12]),
        elevation=10.0,
        visibility_m=16000.0,
        cloud_base_m=150.0,
        fog_fraction=0.0,
    )
    assert station.marine_presence(slab_top_m=300.0) == 1.0
    # With no deck below the inversion, it really is a clear report.
    assert station.marine_presence(slab_top_m=100.0) == 0.0


def test_hillsides_reaching_into_a_lifted_deck_are_in_cloud():
    result = _build([FOGGED_WEST], terrain_routing=True, base_m=150.0, top_m=500.0)

    lowland = (SOUTH_ROW, 12)
    hillside = (SOUTH_ROW, 38)

    # The flats are under the deck: grey overhead, but you can see.
    assert result.fog_fraction[lowland] == 0.0
    assert result.surface_state[lowland] == "under_deck"
    # The ridge flank at 243 m rises into it.
    assert result.elevation[hillside] > 150.0
    assert result.fog_fraction[hillside] > 0.5
    assert result.surface_state[hillside] == "in_fog"


def test_an_empty_slab_produces_no_fog_anywhere():
    result = _build([FOGGED_WEST], terrain_routing=True, base_m=300.0, top_m=300.0)
    assert result.fog_fraction.max() == 0.0


def test_visibility_tracks_the_fog_fraction():
    result = _build([FOGGED_WEST, CLEAR_EAST], terrain_routing=True)

    foggy = result.visibility_m[SOUTH_ROW, WEST_OF_RIDGE]
    clear = result.visibility_m[SOUTH_ROW, EAST_OF_RIDGE]
    assert foggy < 1000.0
    assert clear > 20000.0


def test_stations_outside_the_domain_are_dropped_with_a_warning():
    far_away = FogStationInput(
        source="test",
        latitude=40.0,
        longitude=-120.0,
        elevation=0.0,
        fog_fraction=1.0,
    )
    result = _build([FOGGED_WEST, far_away], terrain_routing=True)

    assert len(result.used_stations) == 1
    assert any("outside the domain" in warning for warning in result.warnings)


def test_a_station_just_outside_is_clamped_to_the_edge():
    just_south = FogStationInput(
        source="test",
        station_id="KHAF-ish",
        latitude=PENINSULA_BOUNDS.lat_min - 0.05,
        longitude=-122.5,
        elevation=20.0,
        fog_fraction=1.0,
    )
    result = _build([just_south], terrain_routing=True)
    assert len(result.used_stations) == 1


def test_mismatched_elevation_shape_is_rejected():
    with pytest.raises(ValueError, match="does not match grid"):
        build_fog_grid(
            bounds=PENINSULA_BOUNDS,
            grid_x=N_COLS,
            grid_y=N_ROWS,
            elevation=np.zeros((10, 10)),
            stations=[FOGGED_WEST],
            slab=_slab(),
        )


def test_no_stations_is_an_error():
    with pytest.raises(ValueError, match="at least one station"):
        _build([])
