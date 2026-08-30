from dataclasses import dataclass

import numpy as np
import pytest

from app.features.fog import (
    diagnose_slab,
    froude_number,
    inversion_base,
    inversion_theta_jump,
    lcl_height_m,
    observed_fog_fraction,
    slab_occupancy,
    visibility_from_fog_fraction,
)


@dataclass(frozen=True)
class Level:
    pressure_hpa: int
    temperature_c: float
    height_m: float


# A textbook summer Bay Area sounding: cool marine air to ~300 m, then a sharp
# subsidence inversion, then warm dry air above.
MARINE_SOUNDING = [
    Level(1000, 13.0, 110.0),
    Level(950, 12.4, 300.0),
    Level(925, 18.5, 560.0),
    Level(900, 19.0, 800.0),
    Level(850, 16.5, 1500.0),
]

# A well-mixed profile that cools all the way up: no lid, so no marine layer.
MIXED_SOUNDING = [
    Level(1000, 22.0, 110.0),
    Level(950, 19.0, 300.0),
    Level(925, 17.0, 560.0),
    Level(900, 15.0, 800.0),
]


def test_lcl_follows_espy():
    assert lcl_height_m(15.0, 13.0) == 250.0
    # Saturated air condenses at the surface.
    assert lcl_height_m(14.0, 14.0) == 0.0
    # A negative depression is unphysical, not a negative cloud base.
    assert lcl_height_m(12.0, 14.0) == 0.0


def test_inversion_base_finds_the_lid():
    found = inversion_base(MARINE_SOUNDING)
    assert found is not None
    height, strength = found
    assert height == 300.0
    assert strength == pytest.approx(6.1)


def test_inversion_base_is_none_when_the_profile_only_cools():
    assert inversion_base(MIXED_SOUNDING) is None
    assert inversion_theta_jump(MIXED_SOUNDING) is None


def test_inversion_base_is_order_independent():
    assert inversion_base(list(reversed(MARINE_SOUNDING))) == inversion_base(
        MARINE_SOUNDING
    )


def test_froude_number_separates_blocked_from_overtopping():
    jump = inversion_theta_jump(MARINE_SOUNDING)
    assert jump is not None and jump > 0

    light = froude_number(2.0, 300.0, jump)
    strong = froude_number(20.0, 300.0, jump)
    assert light is not None and strong is not None
    assert light < 1.0 < strong

    # Degenerate inputs return None rather than dividing by zero.
    assert froude_number(5.0, 0.0, jump) is None
    assert froude_number(5.0, 300.0, 0.0) is None


def test_observed_fog_fraction_prefers_measured_visibility():
    assert observed_fog_fraction(visibility_m=400.0, dew_point_depression_c=None,
                                 low_cloud_fraction=None) == 1.0
    assert observed_fog_fraction(visibility_m=16000.0, dew_point_depression_c=None,
                                 low_cloud_fraction=None) == 0.0
    mid = observed_fog_fraction(visibility_m=5000.0, dew_point_depression_c=None,
                                low_cloud_fraction=None)
    assert 0.0 < mid < 1.0


def test_observed_fog_fraction_falls_back_without_visibility():
    saturated = observed_fog_fraction(
        visibility_m=None, dew_point_depression_c=0.0, low_cloud_fraction=1.0
    )
    dry = observed_fog_fraction(
        visibility_m=None, dew_point_depression_c=8.0, low_cloud_fraction=0.0
    )
    assert saturated == pytest.approx(1.0)
    assert dry == 0.0


def test_present_weather_raises_a_generous_visibility_report():
    # An observer reporting FG outranks a visibility that looks marginal.
    assert observed_fog_fraction(
        visibility_m=9000.0, dew_point_depression_c=None,
        low_cloud_fraction=None, reports_fog=True
    ) == 0.85


def test_slab_occupancy_is_a_level_set_against_terrain():
    elevation = np.array([[0.0, 100.0, 239.0, 281.0, 400.0, 784.0]])
    occupancy = slab_occupancy(elevation, base_m=0.0, top_m=240.0, feather_m=30.0)

    # Below the top: in the slab.
    assert occupancy[0, 1] == pytest.approx(1.0)
    # Twin Peaks at 281 m pokes through a 240 m top, so it is out.
    assert occupancy[0, 3] == 0.0
    # Mount Tamalpais is far above it.
    assert occupancy[0, 5] == 0.0
    # The transition is monotonic, which is what makes the edge trace a contour.
    assert occupancy[0, 2] > occupancy[0, 3]


def test_slab_occupancy_excludes_ground_below_a_lifted_deck():
    elevation = np.array([[5.0, 200.0]])
    occupancy = slab_occupancy(elevation, base_m=150.0, top_m=400.0, feather_m=30.0)
    # Downtown, under the deck: grey overhead but not in cloud.
    assert occupancy[0, 0] == 0.0
    # A hillside that reaches into the deck is in cloud.
    assert occupancy[0, 1] == pytest.approx(1.0)


def test_visibility_mapping_is_monotonic_and_bounded():
    fractions = np.array([0.0, 0.25, 0.5, 0.75, 1.0])
    visibility = visibility_from_fog_fraction(fractions, max_visibility_m=24000.0)
    assert visibility[0] == pytest.approx(24000.0)
    assert visibility[-1] < 100.0
    assert np.all(np.diff(visibility) < 0)


def test_diagnose_slab_uses_the_inversion_when_available():
    slab = diagnose_slab(
        levels_by_point=[MARINE_SOUNDING, MARINE_SOUNDING],
        surface_values=[
            {"temperature_2m": 14.0, "dew_point_2m": 13.0},
            {"temperature_2m": 14.0, "dew_point_2m": 13.0},
        ],
        fogged_station_elevations=[],
        observed_ceilings_m=[],
        mean_wind_ms=6.0,
    )
    assert slab.top_m == 300.0
    assert slab.inversion_base_m == 300.0
    assert slab.lcl_m == pytest.approx(125.0)
    assert slab.base_m == pytest.approx(125.0)
    assert slab.blocking_regime in {"blocked", "overtopping"}
    assert slab.warnings == ()


def test_diagnose_slab_warns_and_defaults_without_a_sounding():
    slab = diagnose_slab(
        levels_by_point=[[], []],
        surface_values=[{"temperature_2m": 15.0, "dew_point_2m": 14.5}],
        fogged_station_elevations=[],
        observed_ceilings_m=[],
        default_top_m=280.0,
    )
    assert slab.top_m == 280.0
    assert slab.warnings
    assert "default" in slab.source


def test_boundary_layer_height_is_used_before_the_default():
    slab = diagnose_slab(
        levels_by_point=[[]],
        surface_values=[
            {"temperature_2m": 15.0, "dew_point_2m": 14.0,
             "boundary_layer_height": 420.0}
        ],
        fogged_station_elevations=[],
        observed_ceilings_m=[],
        default_top_m=280.0,
    )
    assert slab.top_m == 420.0
    assert "boundary layer" in slab.source


def test_a_fogged_station_forces_the_slab_to_cover_it():
    # The model says the lid is at 300 m, but a station at 380 m is reporting
    # fog. The observation is a hard bound and must win.
    slab = diagnose_slab(
        levels_by_point=[MARINE_SOUNDING],
        surface_values=[{"temperature_2m": 14.0, "dew_point_2m": 13.0}],
        fogged_station_elevations=[380.0],
        observed_ceilings_m=[],
    )
    assert slab.top_m > 380.0
    assert slab.base_m <= 380.0


def test_observed_ceiling_sets_the_deck_base():
    slab = diagnose_slab(
        levels_by_point=[MARINE_SOUNDING],
        surface_values=[{"temperature_2m": 18.0, "dew_point_2m": 12.0}],
        fogged_station_elevations=[],
        observed_ceilings_m=[180.0, 200.0, 220.0],
    )
    assert slab.base_m == 200.0
    assert "observed ceilings" in slab.source


def test_a_cloud_base_above_the_inversion_means_no_marine_layer():
    slab = diagnose_slab(
        levels_by_point=[[]],
        surface_values=[{"temperature_2m": 30.0, "dew_point_2m": 0.0}],
        fogged_station_elevations=[],
        observed_ceilings_m=[],
        default_top_m=100.0,
    )
    # The LCL here is 3750 m, far above the 100 m lid: dry, clear, no deck.
    assert slab.base_m == slab.top_m
    assert any("no marine layer" in warning for warning in slab.warnings)
    # And an empty slab must yield no fog rather than a band of half-values.
    assert slab_occupancy(np.linspace(0, 4000, 50), slab.base_m, slab.top_m).max() == 0.0
