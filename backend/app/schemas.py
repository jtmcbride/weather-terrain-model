from typing import Literal

from pydantic import BaseModel, Field

FieldName = Literal["temperature_2m", "precipitation", "wind_speed_10m"]


class Bounds(BaseModel):
    """Geographic extent in WGS84 latitude/longitude coordinates."""

    lat_min: float
    lat_max: float
    lon_min: float
    lon_max: float


class GridRequest(BaseModel):
    """Controls forecast-field sampling and terrain-aware interpolation."""

    field: FieldName = "temperature_2m"
    hour_index: int = Field(default=0, ge=0, le=167)
    grid_x: int = Field(default=48, ge=12, le=80)
    grid_y: int = Field(default=36, ge=12, le=80)
    elevation_weight: float = Field(default=0.62, ge=0.0, le=1.0)
    idw_power: float = Field(default=2.4, ge=1.0, le=6.0)
    bounds: Bounds | None = None


class StationObservation(BaseModel):
    latitude: float
    longitude: float
    elevation: float
    value: float


class ForecastGridResponse(BaseModel):
    time: str
    field: FieldName
    unit: str
    bounds: Bounds
    grid_x: int
    grid_y: int
    values: list[float]
    min_value: float
    max_value: float
    stations: list[StationObservation]
    method: str
