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
