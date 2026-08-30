"""Assembles the fog grid from terrain, a slab diagnosis, and observations."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from app.features.fog import (
    SlabDiagnosis,
    classify_surface,
    slab_occupancy,
    visibility_from_fog_fraction,
)
from app.providers.dem import cell_size_m, raster_coordinates
from app.schemas import Bounds
from app.services.cost_distance import (
    build_cost_graph,
    cell_index,
    cost_distances,
    geographic_distances,
    inverse_distance_weighted,
)

# How far outside the domain a station may sit and still be seeded at the
# nearest edge cell. Beyond this it is dropped rather than misattributed.
STATION_CLAMP_MARGIN_DEG = 0.15


@dataclass(frozen=True)
class FogStationInput:
    """One observation, already collapsed to the quantities the model needs."""

    source: str
    latitude: float
    longitude: float
    elevation: float
    fog_fraction: float
    station_id: str | None = None
    visibility_m: float | None = None
    relative_humidity: float | None = None
    dew_point_depression_c: float | None = None
    cloud_base_m: float | None = None

    @property
    def is_fogged(self) -> bool:
        return self.fog_fraction >= 0.5

    def marine_presence(self, slab_top_m: float) -> float:
        """Whether marine air is over this station at all, fogged or not.

        A station sitting under a stratus deck has excellent surface visibility
        and is still inside the marine air -- the hilltops above it are in cloud
        even though the observer is not. Interpolating surface fog alone would
        wrongly mark that whole area fog-free.
        """
        presence = self.fog_fraction
        if self.cloud_base_m is not None and self.cloud_base_m < slab_top_m:
            presence = max(presence, 1.0)
        return float(np.clip(presence, 0.0, 1.0))


@dataclass(frozen=True)
class FogGridResult:
    fog_fraction: np.ndarray
    visibility_m: np.ndarray
    surface_state: np.ndarray
    marine_influence: np.ndarray
    elevation: np.ndarray
    used_stations: list[FogStationInput]
    method: str
    warnings: list[str]


def _clamped_cell(
    bounds: Bounds, grid_x: int, grid_y: int, station: FogStationInput
) -> int | None:
    index = cell_index(bounds, grid_x, grid_y, station.latitude, station.longitude)
    if index is not None:
        return index
    latitude = min(max(station.latitude, bounds.lat_min), bounds.lat_max)
    longitude = min(max(station.longitude, bounds.lon_min), bounds.lon_max)
    if (
        abs(latitude - station.latitude) > STATION_CLAMP_MARGIN_DEG
        or abs(longitude - station.longitude) > STATION_CLAMP_MARGIN_DEG
    ):
        return None
    return cell_index(bounds, grid_x, grid_y, latitude, longitude)


def build_fog_grid(
    bounds: Bounds,
    grid_x: int,
    grid_y: int,
    elevation: np.ndarray,
    stations: list[FogStationInput],
    slab: SlabDiagnosis,
    terrain_routing: bool = True,
    cost_beta: float = 12.0,
    cost_scale_m: float = 60.0,
    block_buffer_m: float = 25.0,
    idw_power: float = 2.0,
    max_visibility_m: float = 24000.0,
) -> FogGridResult:
    """Interpolate marine influence, then cut it against the terrain.

    The two steps are deliberately separate:

    1. *Horizontal* -- how much marine air reaches each cell, routed around
       terrain that stands above the inversion rather than straight through it.
    2. *Vertical* -- whether the ground at that cell lies inside the slab.

    Multiplying them is what produces a fog edge that follows a hillside
    contour instead of a blurred circle around the nearest station.
    """
    warnings: list[str] = []
    if elevation.shape != (grid_y, grid_x):
        raise ValueError(
            f"elevation shape {elevation.shape} does not match grid "
            f"({grid_y}, {grid_x})"
        )
    if not stations:
        raise ValueError("at least one station observation is required")

    latitudes, longitudes = raster_coordinates(bounds, grid_x, grid_y)
    cell_dy_m, cell_dx_m = cell_size_m(bounds, grid_x, grid_y)

    seeded: list[FogStationInput] = []
    seed_cells: list[int] = []
    for station in stations:
        index = _clamped_cell(bounds, grid_x, grid_y, station)
        if index is None:
            continue
        seeded.append(station)
        seed_cells.append(index)

    dropped = len(stations) - len(seeded)
    if dropped:
        warnings.append(
            f"{dropped} observation(s) fell outside the domain and were not used."
        )
    if not seeded:
        raise ValueError("no observations fall inside the requested bounds")

    presence = np.array(
        [station.marine_presence(slab.top_m) for station in seeded], dtype=np.float64
    )

    if terrain_routing:
        graph = build_cost_graph(
            elevation,
            cell_dy_m=cell_dy_m,
            cell_dx_m=cell_dx_m,
            fog_top_m=slab.top_m,
            beta=cost_beta,
            scale_m=cost_scale_m,
            block_buffer_m=block_buffer_m,
        )
        distances = cost_distances(graph, seed_cells)
        method = (
            "Terrain cost-distance IDW: marine influence is routed around ridges "
            "standing above the diagnosed inversion, then cut vertically against "
            "the DEM by the fog slab."
        )
        isolated = int(np.sum(~np.isfinite(distances).any(axis=1)))
        if isolated:
            warnings.append(
                f"{isolated} observation(s) sit above the inversion and could not "
                "seed the domain."
            )
    else:
        distances = geographic_distances(
            latitudes,
            longitudes,
            [station.latitude for station in seeded],
            [station.longitude for station in seeded],
        )
        method = (
            "Geographic IDW baseline with no terrain routing: influence crosses "
            "ridges unimpeded. Included for comparison."
        )

    influence_flat, reachable = inverse_distance_weighted(
        distances, presence, power=idw_power
    )
    marine_influence = influence_flat.reshape(grid_y, grid_x)
    if not reachable.all():
        blocked = int((~reachable).sum())
        warnings.append(
            f"{blocked} cell(s) are sealed off above the inversion and were set "
            "fog-free."
        )

    occupancy = slab_occupancy(elevation, slab.base_m, slab.top_m)
    fog_fraction = np.clip(marine_influence * occupancy, 0.0, 1.0)
    visibility = visibility_from_fog_fraction(fog_fraction, max_visibility_m)
    states = classify_surface(
        elevation, fog_fraction, marine_influence, slab.base_m, slab.top_m
    )

    return FogGridResult(
        fog_fraction=fog_fraction,
        visibility_m=visibility,
        surface_state=states,
        marine_influence=marine_influence,
        elevation=elevation,
        used_stations=seeded,
        method=method,
        warnings=warnings + list(slab.warnings),
    )
