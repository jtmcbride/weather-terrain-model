from typing import Literal

from pydantic import BaseModel, Field

FieldName = Literal[
    "temperature_2m",
    "precipitation",
    "wind_speed_10m",
    "relative_humidity_2m",
    "dew_point_2m",
    "visibility",
    "cloud_cover_low",
]

FIELD_UNITS: dict[str, str] = {
    "temperature_2m": "°C",
    "precipitation": "mm",
    "wind_speed_10m": "km/h",
    "relative_humidity_2m": "%",
    "dew_point_2m": "°C",
    "visibility": "m",
    "cloud_cover_low": "%",
}

SurfaceState = Literal["above_deck", "in_fog", "under_deck", "clear"]


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


# ----------------------------------------------------------------------
# Fog
# ----------------------------------------------------------------------


class FogGridRequest(BaseModel):
    """Controls marine-layer fog diagnosis and terrain-aware routing.

    The grid caps are much higher than ``GridRequest`` because fog blocking
    only becomes visible once cells are smaller than the ridge doing the
    blocking. A 400 x 400 grid over the default San Francisco domain is
    roughly 100 m per cell.
    """

    hour_index: int = Field(default=0, ge=0, le=167)
    grid_x: int = Field(default=256, ge=32, le=420)
    grid_y: int = Field(default=280, ge=32, le=420)
    bounds: Bounds | None = None

    # Cost-distance controls. `terrain_routing=False` falls back to plain
    # geographic IDW, which is useful for showing what the barrier buys you.
    terrain_routing: bool = True
    cost_beta: float = Field(default=12.0, ge=0.0, le=200.0)
    idw_power: float = Field(default=2.0, ge=1.0, le=6.0)

    # Override the diagnosed fog top, in metres MSL. Useful for exploring
    # "what does the city look like at a 250 m marine layer".
    fog_top_override_m: float | None = Field(default=None, ge=0.0, le=2000.0)
    use_observations: bool = True


class FogStation(BaseModel):
    station_id: str | None = None
    source: str
    latitude: float
    longitude: float
    elevation: float
    visibility_m: float | None = None
    relative_humidity: float | None = None
    dew_point_depression_c: float | None = None
    cloud_base_m: float | None = None
    fog_fraction: float
    is_fogged: bool


class SlabProfile(BaseModel):
    """The diagnosed marine-layer slab, in metres above mean sea level."""

    base_m: float
    top_m: float
    inversion_base_m: float | None = None
    inversion_strength_c: float | None = None
    lcl_m: float | None = None
    froude_number: float | None = None
    blocking_regime: Literal["blocked", "overtopping", "unknown"]
    source: str


class FogGridResponse(BaseModel):
    time: str
    bounds: Bounds
    grid_x: int
    grid_y: int

    # Row-major, length grid_x * grid_y.
    fog_fraction: list[float]
    """0 = clear, 1 = dense fog at the surface. Drives render opacity."""
    visibility_m: list[float]
    elevation_m: list[float]
    surface_state: list[SurfaceState]

    slab: SlabProfile
    stations: list[FogStation]
    min_elevation: float
    max_elevation: float
    method: str
    warnings: list[str] = []
