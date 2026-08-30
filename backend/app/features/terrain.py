from math import sqrt


def normalized(value: float, lower: float, upper: float) -> float:
    """Scale a value to [0, 1], guarding against degenerate ranges."""
    return (value - lower) / max(upper - lower, 1e-9)


def elevation_penalized_distance(
    latitude_a: float,
    longitude_a: float,
    elevation_a: float,
    latitude_b: float,
    longitude_b: float,
    elevation_b: float,
    elevation_weight: float,
) -> float:
    """Blend geographic and terrain separation for interpolation weights.

    Elevation is normalized to an approximate 4,000 m California relief range.
    With ``elevation_weight=0``, this is standard planar geographic distance.
    With ``elevation_weight=1``, similarity is determined only by elevation.
    """
    geographic_distance = sqrt(
        (latitude_a - latitude_b) ** 2 + (longitude_a - longitude_b) ** 2
    )
    terrain_distance = abs(elevation_a - elevation_b) / 4000.0
    return sqrt(
        (1.0 - elevation_weight) * geographic_distance**2
        + elevation_weight * terrain_distance**2
    )


def lapse_rate_temperature_adjustment(
    elevation_m: float, reference_elevation_m: float
) -> float:
    """Return the temperature trend relative to a reference elevation.

    The standard environmental lapse rate is approximately 6.5°C colder per km
    gained in elevation. The residual interpolation layer corrects this baseline
    using observations, so the model does not imply this relationship is exact.
    """
    return -0.0065 * (elevation_m - reference_elevation_m)


# ----------------------------------------------------------------------
# Raster terrain features
# ----------------------------------------------------------------------
# These operate on a 2-D elevation array in north-first raster order (row 0 is
# lat_max), which is what `providers.dem.DemProvider` returns. They are the
# slope/aspect/ruggedness features the project specification calls for and are
# only computable once elevation is a raster rather than a bag of sampled
# points.

import numpy as np


def _gradients(
    elevation: "np.ndarray", cell_dy_m: float, cell_dx_m: float
) -> tuple["np.ndarray", "np.ndarray"]:
    """Return (d_elev/d_north, d_elev/d_east) in metres per metre.

    Row 0 is north, so the row axis increases southward and its gradient is
    negated to give a northward derivative.
    """
    d_row, d_col = np.gradient(np.asarray(elevation, dtype=np.float64))
    return -d_row / cell_dy_m, d_col / cell_dx_m


def slope_radians(
    elevation: "np.ndarray", cell_dy_m: float, cell_dx_m: float
) -> "np.ndarray":
    """Terrain slope, 0 on the flat and pi/2 on a vertical wall."""
    d_north, d_east = _gradients(elevation, cell_dy_m, cell_dx_m)
    return np.arctan(np.hypot(d_north, d_east))


def aspect_radians(
    elevation: "np.ndarray", cell_dy_m: float, cell_dx_m: float
) -> "np.ndarray":
    """Compass direction the slope faces, in radians clockwise from north.

    A west-facing slope -- the side of the San Francisco hills the marine layer
    arrives on -- returns approximately 3*pi/2.
    """
    d_north, d_east = _gradients(elevation, cell_dy_m, cell_dx_m)
    # Downhill direction is the negative gradient.
    return np.mod(np.arctan2(-d_east, -d_north), 2.0 * np.pi)


def terrain_ruggedness(elevation: "np.ndarray") -> "np.ndarray":
    """Riley's Terrain Ruggedness Index: mean |elevation difference| to neighbours."""
    grid = np.asarray(elevation, dtype=np.float64)
    padded = np.pad(grid, 1, mode="edge")
    total = np.zeros_like(grid)
    count = 0
    for row_shift in (-1, 0, 1):
        for col_shift in (-1, 0, 1):
            if row_shift == 0 and col_shift == 0:
                continue
            shifted = padded[
                1 + row_shift : 1 + row_shift + grid.shape[0],
                1 + col_shift : 1 + col_shift + grid.shape[1],
            ]
            total += np.abs(shifted - grid)
            count += 1
    return total / count


def ridge_mask(elevation: "np.ndarray", above_m: float) -> "np.ndarray":
    """Cells that rise above a given altitude -- the barrier for a fog top."""
    return np.asarray(elevation, dtype=np.float64) > above_m
