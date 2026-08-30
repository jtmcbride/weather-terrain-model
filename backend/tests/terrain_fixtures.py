"""Synthetic terrain that reproduces the San Francisco blocking geometry.

A north-south ridge splits the domain, with a sea-level gap at the northern
end standing in for the Golden Gate. Row 0 is north, matching raster order.
"""

import numpy as np

from app.schemas import Bounds

# Roughly the real domain, so cell sizes come out near 100 m.
PENINSULA_BOUNDS = Bounds(
    lat_min=37.44, lat_max=37.95, lon_min=-122.65, lon_max=-122.15
)

RIDGE_COLUMNS = slice(36, 45)
GAP_ROWS = slice(4, 11)


def peninsula(
    n_rows: int = 60,
    n_cols: int = 80,
    crest_m: float = 300.0,
    lowland_m: float = 10.0,
    gap_m: float = 15.0,
) -> np.ndarray:
    """A ridge with one gap at its northern end."""
    elevation = np.full((n_rows, n_cols), lowland_m, dtype=np.float64)

    # Shape the ridge as a smooth hump so cost varies across it rather than
    # jumping, which is how a real DEM behaves.
    columns = np.arange(n_cols)
    centre = (RIDGE_COLUMNS.start + RIDGE_COLUMNS.stop - 1) / 2.0
    half_width = (RIDGE_COLUMNS.stop - RIDGE_COLUMNS.start) / 2.0
    profile = np.clip(1.0 - ((columns - centre) / half_width) ** 2, 0.0, 1.0)
    elevation += profile * (crest_m - lowland_m)

    # Cut the gap.
    elevation[GAP_ROWS, :] = np.minimum(elevation[GAP_ROWS, :], gap_m)
    return elevation


def conical_hill(
    n_rows: int = 61, n_cols: int = 61, summit_m: float = 400.0
) -> np.ndarray:
    """A single cone, for checking that a fog edge traces an elevation contour."""
    rows = np.arange(n_rows) - (n_rows - 1) / 2.0
    cols = np.arange(n_cols) - (n_cols - 1) / 2.0
    radius = np.hypot(rows[:, None], cols[None, :])
    max_radius = radius.max()
    return summit_m * np.clip(1.0 - radius / max_radius, 0.0, 1.0)
