from dataclasses import dataclass

from app.features.terrain import (
    elevation_penalized_distance,
    lapse_rate_temperature_adjustment,
)
from app.providers.open_meteo import ForecastPoint
from app.schemas import Bounds


@dataclass(frozen=True)
class GridCell:
    latitude: float
    longitude: float
    elevation: float
    value: float


def coordinate_lattice(bounds: Bounds, grid_x: int, grid_y: int) -> list[tuple[float, float]]:
    """Return a row-major set of evenly spaced WGS84 grid coordinates."""
    return [
        (
            bounds.lat_min + y * (bounds.lat_max - bounds.lat_min) / (grid_y - 1),
            bounds.lon_min + x * (bounds.lon_max - bounds.lon_min) / (grid_x - 1),
        )
        for y in range(grid_y)
        for x in range(grid_x)
    ]


def station_lattice(bounds: Bounds, columns: int = 7, rows: int = 6) -> list[tuple[float, float]]:
    """Small source lattice used until real station observations are added."""
    return coordinate_lattice(bounds, columns, rows)


def predict_grid(
    bounds: Bounds,
    grid_x: int,
    grid_y: int,
    elevations: list[float],
    stations: list[ForecastPoint],
    field: str,
    elevation_weight: float,
    idw_power: float,
) -> list[GridCell]:
    """Build a terrain-aware IDW prediction grid.

    Temperature observations are decomposed into a lapse-rate terrain trend and
    residual. Only residuals are interpolated, then the target-cell terrain trend
    is restored. Other fields use elevation-penalized IDW directly.
    """
    if not stations:
        raise ValueError("At least one station observation is required")

    coordinates = coordinate_lattice(bounds, grid_x, grid_y)
    if len(coordinates) != len(elevations):
        raise ValueError("Each grid coordinate must have one elevation value")

    reference_elevation = sum(point.elevation for point in stations) / len(stations)
    cells: list[GridCell] = []

    for (latitude, longitude), elevation in zip(coordinates, elevations):
        weighted_value = 0.0
        weight_sum = 0.0
        target_trend = (
            lapse_rate_temperature_adjustment(elevation, reference_elevation)
            if field == "temperature_2m"
            else 0.0
        )

        for station in stations:
            observed_value = station.values[field]
            station_trend = (
                lapse_rate_temperature_adjustment(station.elevation, reference_elevation)
                if field == "temperature_2m"
                else 0.0
            )
            residual = observed_value - station_trend
            distance = elevation_penalized_distance(
                latitude,
                longitude,
                elevation,
                station.latitude,
                station.longitude,
                station.elevation,
                elevation_weight,
            )
            weight = 1.0 / max(distance, 1e-5) ** idw_power
            weighted_value += weight * residual
            weight_sum += weight

        cells.append(
            GridCell(
                latitude=latitude,
                longitude=longitude,
                elevation=elevation,
                value=target_trend + weighted_value / weight_sum,
            )
        )

    return cells
