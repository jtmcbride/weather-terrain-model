"""Terrain cost distance for fog routing.

``features.terrain.elevation_penalized_distance`` blends horizontal separation
with elevation *difference*. That is a similarity metric, not a barrier metric:
it says two points at the same elevation are meteorologically alike, which is
defensible for temperature under a lapse rate and exactly wrong for fog. Two
sea-level neighbourhoods on opposite sides of a 281 m ridge score as nearly
identical under it, so a fogged observation on the west side flows straight
through the hill.

This module replaces "how far apart are these two points" with "what is the
cheapest path the marine air could actually take between them", where climbing
towards the inversion is expensive and rising through it is impossible. An
observation in the Sunset can then only reach the Mission by routing north
through the Golden Gate or south through the San Bruno Gap -- which is how the
air itself gets there.
"""

from __future__ import annotations

import numpy as np
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import dijkstra

# (row shift, column shift) for an 8-connected grid. Row 0 is north.
NEIGHBOUR_OFFSETS = (
    (-1, 0), (1, 0), (0, -1), (0, 1),
    (-1, -1), (-1, 1), (1, -1), (1, 1),
)

MIN_DISTANCE_M = 1.0


def build_cost_graph(
    elevation: np.ndarray,
    cell_dy_m: float,
    cell_dx_m: float,
    fog_top_m: float,
    beta: float = 12.0,
    scale_m: float = 60.0,
    block_buffer_m: float = 25.0,
) -> coo_matrix:
    """Build the sparse traversal graph for a given fog top.

    An edge between two cells costs its horizontal length times a penalty that
    grows once the higher of the two cells rises above the fog top, and the edge
    disappears entirely once that crest clears the top by ``block_buffer_m``.
    The graph therefore has to be rebuilt whenever the diagnosed top changes,
    which is fine -- it is a handful of vectorised operations.
    """
    grid = np.asarray(elevation, dtype=np.float64)
    if grid.ndim != 2:
        raise ValueError("elevation must be a 2-D array")
    n_rows, n_cols = grid.shape
    indices = np.arange(n_rows * n_cols).reshape(n_rows, n_cols)
    impassable_above = fog_top_m + block_buffer_m

    all_sources: list[np.ndarray] = []
    all_targets: list[np.ndarray] = []
    all_costs: list[np.ndarray] = []

    for row_shift, col_shift in NEIGHBOUR_OFFSETS:
        row_start, row_stop = max(0, -row_shift), n_rows - max(0, row_shift)
        col_start, col_stop = max(0, -col_shift), n_cols - max(0, col_shift)
        if row_start >= row_stop or col_start >= col_stop:
            continue

        source_idx = indices[row_start:row_stop, col_start:col_stop]
        target_idx = indices[
            row_start + row_shift : row_stop + row_shift,
            col_start + col_shift : col_stop + col_shift,
        ]
        source_elev = grid[row_start:row_stop, col_start:col_stop]
        target_elev = grid[
            row_start + row_shift : row_stop + row_shift,
            col_start + col_shift : col_stop + col_shift,
        ]

        crest = np.maximum(source_elev, target_elev)
        span_m = float(np.hypot(row_shift * cell_dy_m, col_shift * cell_dx_m))
        penalty = 1.0 + beta * np.maximum(0.0, (crest - fog_top_m) / max(scale_m, 1e-6))
        cost = span_m * penalty

        passable = crest <= impassable_above
        all_sources.append(source_idx[passable])
        all_targets.append(target_idx[passable])
        all_costs.append(cost[passable])

    if not all_sources:
        raise ValueError("elevation grid is too small to build a graph")

    return coo_matrix(
        (
            np.concatenate(all_costs),
            (np.concatenate(all_sources), np.concatenate(all_targets)),
        ),
        shape=(n_rows * n_cols, n_rows * n_cols),
    ).tocsr()


def cost_distances(graph, source_indices: list[int]) -> np.ndarray:
    """Cost distance from each source cell to every cell.

    Returns a ``(len(source_indices), n_cells)`` array. Unreachable cells --
    those walled off by terrain above the inversion -- are ``inf``, which the
    weighting below turns into zero influence rather than an error.
    """
    if not source_indices:
        raise ValueError("at least one source cell is required")
    distances = dijkstra(graph, indices=np.asarray(source_indices), directed=True)
    return np.atleast_2d(distances)


def geographic_distances(
    latitudes: np.ndarray,
    longitudes: np.ndarray,
    station_lat: list[float],
    station_lon: list[float],
) -> np.ndarray:
    """Straight-line distances in metres, for the no-terrain-routing baseline."""
    mean_lat = np.radians(float(np.mean(latitudes)))
    metres_per_deg_lat = 111_320.0
    metres_per_deg_lon = 111_320.0 * np.cos(mean_lat)
    rows = []
    for lat, lon in zip(station_lat, station_lon):
        d_north = (latitudes - lat) * metres_per_deg_lat
        d_east = (longitudes - lon) * metres_per_deg_lon
        rows.append(np.hypot(d_north, d_east).ravel())
    return np.vstack(rows)


def inverse_distance_weighted(
    distances: np.ndarray, values: np.ndarray, power: float = 2.0
) -> tuple[np.ndarray, np.ndarray]:
    """Weight station values by inverse cost distance.

    Returns ``(interpolated, reachable)``. Cells no station can reach get 0 and
    are flagged unreachable, which for a fog field is the correct answer: if no
    marine air can get there, there is no fog there.
    """
    finite = np.isfinite(distances)
    clamped = np.where(finite, np.maximum(distances, MIN_DISTANCE_M), np.inf)
    with np.errstate(divide="ignore", over="ignore"):
        weights = np.where(finite, clamped ** (-power), 0.0)

    weight_sum = weights.sum(axis=0)
    reachable = weight_sum > 0
    numerator = (weights * np.asarray(values, dtype=np.float64)[:, None]).sum(axis=0)
    interpolated = np.where(reachable, numerator / np.where(reachable, weight_sum, 1.0), 0.0)
    return interpolated, reachable


def cell_index(
    bounds, grid_x: int, grid_y: int, latitude: float, longitude: float
) -> int | None:
    """Index of the raster cell containing a point, or None if outside.

    Raster order: row 0 is the north edge.
    """
    if not (bounds.lat_min <= latitude <= bounds.lat_max):
        return None
    if not (bounds.lon_min <= longitude <= bounds.lon_max):
        return None
    lat_span = bounds.lat_max - bounds.lat_min
    lon_span = bounds.lon_max - bounds.lon_min
    if lat_span <= 0 or lon_span <= 0:
        return None
    row = int(round((bounds.lat_max - latitude) / lat_span * (grid_y - 1)))
    col = int(round((longitude - bounds.lon_min) / lon_span * (grid_x - 1)))
    row = min(max(row, 0), grid_y - 1)
    col = min(max(col, 0), grid_x - 1)
    return row * grid_x + col
