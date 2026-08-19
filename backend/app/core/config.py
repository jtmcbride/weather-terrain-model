from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Runtime configuration for the terrain-aware weather API."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "Terrain Weather API"
    api_prefix: str = "/v1"

    # Northern California default domain: coast, Central Valley, and Sierra Nevada.
    bounds_lat_min: float = 36.6
    bounds_lat_max: float = 39.6
    bounds_lon_min: float = -123.6
    bounds_lon_max: float = -119.6

    default_grid_x: int = 48
    default_grid_y: int = 36
    default_elevation_weight: float = 0.62
    default_idw_power: float = 2.4
    request_timeout_seconds: float = 30.0


settings = Settings()
