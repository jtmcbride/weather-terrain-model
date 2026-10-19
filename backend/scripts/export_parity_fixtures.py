"""Record the backend fog model's outputs for the Swift port to reproduce.

The Swift FogKit package (ios/FogKit) re-implements features/fog.py,
services/cost_distance.py and services/fog_model.py. Its physics tests are
ported from this repo's tests and are the real specification; these fixtures
are a second, narrower check that the *port* computes the same numbers --
including on the real San Francisco DEM, where Dijkstra routes around hundreds
of ridges rather than one synthetic hump.

Regenerate whenever the model changes (needs the DEM cache: run fetch_dem):

    cd backend && python -m scripts.export_parity_fixtures

Writes ios/FogKit/Tests/FogKitTests/Fixtures/{parity.json, sf-160x176.f32}.
Grids are base64: elevation as raw little-endian float32 (the model is run on
the float32-rounded values, so both sides see identical inputs), outputs as
float32, surface states as one uint8 code per cell.
"""

from __future__ import annotations

import base64
import json
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.config import settings  # noqa: E402
from app.features.fog import (  # noqa: E402
    SlabDiagnosis,
    diagnose_slab,
    override_slab_top,
)
from app.providers.dem import _cache_key  # noqa: E402
from app.schemas import Bounds  # noqa: E402
from app.services.cost_distance import cell_index  # noqa: E402
from app.services.fog_model import FogStationInput, build_fog_grid  # noqa: E402
from tests.terrain_fixtures import (  # noqa: E402
    PENINSULA_BOUNDS,
    conical_hill,
    peninsula,
)

REPO = Path(__file__).resolve().parents[2]
OUT_DIR = REPO / "ios" / "FogKit" / "Tests" / "FogKitTests" / "Fixtures"
DEM_CACHE = REPO / "backend" / ".dem-cache"
SF_GRID = (160, 176)
STATE_CODES = {"clear": 0, "under_deck": 1, "above_deck": 2, "in_fog": 3}


@dataclass(frozen=True)
class Level:
    pressure_hpa: float
    temperature_c: float
    height_m: float


MARINE_SOUNDING = [
    Level(1000, 13.0, 110.0),
    Level(950, 12.4, 300.0),
    Level(925, 18.5, 560.0),
    Level(900, 19.0, 800.0),
    Level(850, 16.5, 1500.0),
]
DEEP_SOUNDING = [
    Level(1000, 14.0, 105.0),
    Level(950, 12.0, 480.0),
    Level(925, 11.6, 690.0),
    Level(900, 15.5, 930.0),
]
MIXED_SOUNDING = [
    Level(1000, 22.0, 110.0),
    Level(950, 19.0, 300.0),
    Level(925, 17.0, 560.0),
    Level(900, 15.0, 800.0),
]


def b64(array: np.ndarray, dtype: str) -> str:
    return base64.b64encode(np.ascontiguousarray(array, dtype=dtype).tobytes()).decode()


def bounds_json(bounds: Bounds) -> dict:
    return {
        "lat_min": bounds.lat_min,
        "lat_max": bounds.lat_max,
        "lon_min": bounds.lon_min,
        "lon_max": bounds.lon_max,
    }


def slab_json(slab: SlabDiagnosis) -> dict:
    return {
        "base_m": slab.base_m,
        "top_m": slab.top_m,
        "inversion_base_m": slab.inversion_base_m,
        "inversion_strength_c": slab.inversion_strength_c,
        "lcl_m": slab.lcl_m,
        "froude_number": slab.froude_number,
        "blocking_regime": slab.blocking_regime,
        "source": slab.source,
        "warnings": list(slab.warnings),
    }


def station_json(station: FogStationInput) -> dict:
    return {
        "source": station.source,
        "station_id": station.station_id,
        "latitude": station.latitude,
        "longitude": station.longitude,
        "elevation": station.elevation,
        "fog_fraction": station.fog_fraction,
        "cloud_base_m": station.cloud_base_m,
    }


def grid_case(
    name: str,
    bounds: Bounds,
    elevation: np.ndarray,
    stations: list[FogStationInput],
    slab: SlabDiagnosis,
    *,
    elevation_file: str | None = None,
    terrain_routing: bool = True,
    edge_feather_m: float = 30.0,
) -> dict:
    # Round to float32 first: that is what the fixture stores, so it is what
    # both implementations must be run on.
    elevation = elevation.astype("<f4").astype(np.float64)
    grid_y, grid_x = elevation.shape
    result = build_fog_grid(
        bounds=bounds,
        grid_x=grid_x,
        grid_y=grid_y,
        elevation=elevation,
        stations=stations,
        slab=slab,
        terrain_routing=terrain_routing,
        cost_beta=settings.fog_cost_beta,
        cost_scale_m=settings.fog_cost_scale_m,
        block_buffer_m=settings.fog_block_buffer_m,
        idw_power=settings.fog_idw_power,
        max_visibility_m=settings.max_visibility_m,
        edge_feather_m=edge_feather_m,
    )
    states = np.vectorize(STATE_CODES.__getitem__)(result.surface_state)
    case = {
        "name": name,
        "bounds": bounds_json(bounds),
        "grid_x": grid_x,
        "grid_y": grid_y,
        "stations": [station_json(station) for station in stations],
        "slab": slab_json(slab),
        "terrain_routing": terrain_routing,
        "edge_feather_m": edge_feather_m,
        "expected": {
            "fog_fraction": b64(result.fog_fraction, "<f4"),
            "marine_influence": b64(result.marine_influence, "<f4"),
            "surface_state": b64(states, "u1"),
            "used_station_ids": [s.station_id for s in result.used_stations],
            "warnings": result.warnings,
        },
    }
    if elevation_file:
        case["elevation_file"] = elevation_file
    else:
        case["elevation"] = b64(elevation, "<f4")
    print(
        f"  {name}: {grid_x}x{grid_y}, fog max {result.fog_fraction.max():.3f}, "
        f"{len(result.warnings)} warning(s)"
    )
    return case


def synthetic_cases() -> list[dict]:
    rows, cols, south_row = 60, 80, 40
    lats = np.linspace(PENINSULA_BOUNDS.lat_max, PENINSULA_BOUNDS.lat_min, rows)
    lons = np.linspace(PENINSULA_BOUNDS.lon_min, PENINSULA_BOUNDS.lon_max, cols)

    def station(col: int, fog: float, name: str) -> FogStationInput:
        return FogStationInput(
            source="test", station_id=name, latitude=float(lats[south_row]),
            longitude=float(lons[col]), elevation=10.0, fog_fraction=fog,
        )

    pair = [station(12, 1.0, "WEST"), station(50, 0.0, "EAST")]
    slab = SlabDiagnosis(
        base_m=0.0, top_m=240.0, inversion_base_m=240.0, inversion_strength_c=6.0,
        lcl_m=0.0, froude_number=0.6, blocking_regime="blocked", source="test",
    )
    terrain = peninsula(rows, cols)
    cone = conical_hill(61, 61, summit_m=400.0)
    cone_lats = np.linspace(PENINSULA_BOUNDS.lat_max, PENINSULA_BOUNDS.lat_min, 61)
    cone_lons = np.linspace(PENINSULA_BOUNDS.lon_min, PENINSULA_BOUNDS.lon_max, 61)
    corner = FogStationInput(
        source="test", station_id="CORNER", latitude=float(cone_lats[60]),
        longitude=float(cone_lons[0]), elevation=float(cone[60, 0]), fog_fraction=1.0,
    )
    return [
        grid_case("peninsula-routed", PENINSULA_BOUNDS, terrain, pair, slab),
        grid_case("peninsula-straight", PENINSULA_BOUNDS, terrain, pair, slab,
                  terrain_routing=False),
        grid_case("peninsula-lifted-deck", PENINSULA_BOUNDS, terrain, pair[:1],
                  override_slab_top(SlabDiagnosis(**{**slab.__dict__, "base_m": 150.0}), 500.0)),
        grid_case("cone-contour", PENINSULA_BOUNDS, cone, [corner],
                  SlabDiagnosis(**{**slab.__dict__, "top_m": 200.0})),
    ]


def sf_cases() -> list[dict]:
    """The real DEM, with a coastal-fogged / bay-clear station set."""
    bounds = Bounds(
        lat_min=settings.fog_bounds_lat_min, lat_max=settings.fog_bounds_lat_max,
        lon_min=settings.fog_bounds_lon_min, lon_max=settings.fog_bounds_lon_max,
    )
    grid_x, grid_y = SF_GRID
    path = DEM_CACHE / f"dem-{_cache_key(bounds, grid_x, grid_y)}.npy"
    if not path.exists():
        sys.exit(f"missing {path.name}: run `python -m scripts.fetch_dem --grid {grid_x}x{grid_y}`")
    elevation = np.load(path).astype("<f4")
    elevation_file = f"sf-{grid_x}x{grid_y}.f32"
    elevation.tofile(OUT_DIR / elevation_file)
    elevation = elevation.astype(np.float64)

    def ground(lat: float, lon: float) -> float:
        index = cell_index(bounds, grid_x, grid_y, lat, lon)
        return float(elevation.ravel()[index]) if index is not None else 0.0

    stations: list[FogStationInput] = []
    for i, lat in enumerate(np.linspace(bounds.lat_min, bounds.lat_max, 5)):
        for j, lon in enumerate(np.linspace(bounds.lon_min, bounds.lon_max, 5)):
            # Fogged on the ocean, thinning over the peninsula, clear in the bay.
            fog = 1.0 if lon < -122.52 else 0.55 if lon < -122.42 else 0.05
            stations.append(FogStationInput(
                source="open-meteo", station_id=f"L{i}{j}", latitude=float(lat),
                longitude=float(lon), elevation=ground(lat, lon), fog_fraction=fog,
            ))
    stations += [
        # Clear at the surface but under a 300 m ceiling: marine air present.
        FogStationInput(source="metar", station_id="KSFO", latitude=37.619,
                        longitude=-122.375, elevation=4.0, fog_fraction=0.0,
                        cloud_base_m=300.0),
        FogStationInput(source="metar", station_id="KHAF", latitude=37.513,
                        longitude=-122.501, elevation=20.0, fog_fraction=1.0),
        FogStationInput(source="metar", station_id="KOAK", latitude=37.721,
                        longitude=-122.221, elevation=3.0, fog_fraction=0.0),
        # Outside the clamp margin: must be dropped with a warning.
        FogStationInput(source="metar", station_id="KSAC", latitude=38.51,
                        longitude=-121.49, elevation=8.0, fog_fraction=0.0),
    ]
    # As main.fog_grid: only METARs are hard bounds on the slab.
    observed = [s for s in stations if s.source == "metar"]
    diagnosed = diagnose_slab(
        levels_by_point=[MARINE_SOUNDING, MARINE_SOUNDING, DEEP_SOUNDING],
        surface_values=[{"temperature_2m": 14.0, "dew_point_2m": 13.4}],
        fogged_station_elevations=[s.elevation for s in observed if s.is_fogged],
        observed_ceilings_m=[300.0],
        clear_station_elevations=[s.elevation for s in observed if s.fog_fraction < 0.2],
        mean_wind_ms=5.5,
    )
    return [
        grid_case("sf-diagnosed", bounds, elevation, stations, diagnosed,
                  elevation_file=elevation_file),
        grid_case("sf-override-250-soft", bounds, elevation, stations,
                  override_slab_top(diagnosed, 250.0), elevation_file=elevation_file,
                  edge_feather_m=60.0),
    ]


def slab_cases() -> list[dict]:
    def levels_json(levels):
        return [vars(level) for level in levels]

    inputs = [
        dict(name="marine", levels_by_point=[MARINE_SOUNDING, DEEP_SOUNDING, MARINE_SOUNDING],
             surface_values=[{"temperature_2m": 14.0, "dew_point_2m": 13.0},
                             {"temperature_2m": 15.0, "dew_point_2m": 13.2}],
             fogged_station_elevations=[], observed_ceilings_m=[], mean_wind_ms=6.0),
        dict(name="fogged-above-lid", levels_by_point=[MARINE_SOUNDING],
             surface_values=[{"temperature_2m": 14.0, "dew_point_2m": 13.0}],
             fogged_station_elevations=[380.0, 12.0], observed_ceilings_m=[]),
        dict(name="ceilings-and-clear-ridge", levels_by_point=[DEEP_SOUNDING],
             surface_values=[{"temperature_2m": 18.0, "dew_point_2m": 12.0}],
             fogged_station_elevations=[5.0], observed_ceilings_m=[180.0, 200.0, 260.0, 220.0],
             clear_station_elevations=[410.0, 3.0], mean_wind_ms=14.0),
        dict(name="boundary-layer", levels_by_point=[[], MIXED_SOUNDING],
             surface_values=[{"temperature_2m": 15.0, "dew_point_2m": 14.0,
                              "boundary_layer_height": 420.0},
                             {"boundary_layer_height": 380.0}],
             fogged_station_elevations=[], observed_ceilings_m=[]),
        dict(name="dry-default", levels_by_point=[[]],
             surface_values=[{"temperature_2m": 30.0, "dew_point_2m": 0.0}],
             fogged_station_elevations=[], observed_ceilings_m=[], default_top_m=100.0),
    ]
    cases = []
    for spec in inputs:
        name = spec.pop("name")
        slab = diagnose_slab(**spec)
        override = override_slab_top(slab, 262.5)
        cases.append({
            "name": name,
            "levels_by_point": [levels_json(levels) for levels in spec["levels_by_point"]],
            "surface_values": spec["surface_values"],
            "fogged_station_elevations": spec["fogged_station_elevations"],
            "observed_ceilings_m": spec["observed_ceilings_m"],
            "clear_station_elevations": spec.get("clear_station_elevations", []),
            "default_top_m": spec.get("default_top_m", 300.0),
            "mean_wind_ms": spec.get("mean_wind_ms"),
            "expected": slab_json(slab),
            "expected_override_262_5": slab_json(override),
        })
        print(f"  slab {name}: base {slab.base_m:.1f}, top {slab.top_m:.1f}, {slab.blocking_regime}")
    return cases


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print("grids:")
    grids = synthetic_cases() + sf_cases()
    print("slabs:")
    slabs = slab_cases()
    out = OUT_DIR / "parity.json"
    out.write_text(json.dumps({
        "generated_by": "backend/scripts/export_parity_fixtures.py",
        "grids": grids,
        "slabs": slabs,
    }, indent=1))
    print(f"wrote {out.relative_to(REPO)} ({out.stat().st_size / 1024:.0f} KiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
