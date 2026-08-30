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

    # ------------------------------------------------------------------
    # San Francisco fog domain
    # ------------------------------------------------------------------
    # Half Moon Bay and the San Bruno Gap in the south through the Marin
    # Headlands and Mount Tamalpais in the north, out to the East Bay hills.
    # The southern edge is pulled down to 37.44 so KHAF sits inside the domain:
    # it is the coastal half of the KHAF/KSFO pair that disagrees whenever the
    # peninsula hills are holding fog on the west side.
    # Roughly 44 km x 57 km, so a 420 x 420 grid resolves ~105-135 m cells,
    # which is about the practical limit of the Copernicus GLO-90 DEM anyway.
    fog_bounds_lat_min: float = 37.44
    fog_bounds_lat_max: float = 37.95
    fog_bounds_lon_min: float = -122.65
    fog_bounds_lon_max: float = -122.15

    fog_default_grid_x: int = 256
    fog_default_grid_y: int = 280

    # Cost-distance interpolation. `beta` scales how expensive it is to route
    # fog over terrain that pokes above the inversion; `block_buffer_m` is how
    # far above the fog top a ridge must rise before it becomes impassable.
    fog_cost_beta: float = 12.0
    fog_cost_scale_m: float = 60.0
    fog_block_buffer_m: float = 25.0
    fog_idw_power: float = 2.0

    # Fog diagnosis thresholds.
    fog_visibility_m: float = 1000.0        # WMO: fog is visibility under 1 km
    mist_visibility_m: float = 5000.0
    max_visibility_m: float = 24000.0       # Open-Meteo clamps around 24 km
    fog_dewpoint_depression_c: float = 2.5
    fog_low_cloud_percent: float = 80.0
    default_fog_top_m: float = 300.0        # fallback marine layer depth

    # ------------------------------------------------------------------
    # Terrain / DEM
    # ------------------------------------------------------------------
    dem_cache_dir: str = "/app/.dem-cache"
    # Optional path to a local DEM GeoTIFF (e.g. a Copernicus GLO-90 tile).
    # When set and rasterio is installed, elevations are read from it instead
    # of the Open-Meteo elevation endpoint, which removes the network round
    # trip from the render path entirely.
    dem_raster_path: str | None = None

    # ------------------------------------------------------------------
    # Observations
    # ------------------------------------------------------------------
    metar_url: str = "https://aviationweather.gov/api/data/metar"
    # Bay Area reporting stations. KHAF (coastal, Half Moon Bay) versus KSFO
    # (bay side) is the canonical pair that disagrees when the hills hold the
    # fog on one side.
    metar_station_ids: list[str] = [
        "KSFO", "KOAK", "KHAF", "KSQL", "KPAO", "KNUQ",
        "KHWD", "KCCR", "KAPC", "KDVO", "KSTS", "KLVK",
    ]
    metar_max_age_minutes: int = 90
    use_metar_observations: bool = True


settings = Settings()
