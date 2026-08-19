from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import settings
from app.providers.open_meteo import OpenMeteoClient
from app.schemas import Bounds, ForecastGridResponse, GridRequest, StationObservation
from app.services.grid_builder import coordinate_lattice, predict_grid, station_lattice

app = FastAPI(title=settings.app_name, version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:8080", "http://localhost:3000", "null"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

client = OpenMeteoClient(settings.request_timeout_seconds)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post(f"{settings.api_prefix}/forecast-grid", response_model=ForecastGridResponse)
async def forecast_grid(request: GridRequest) -> ForecastGridResponse:
    """Fetch forecast samples, terrain data, and return an interpolated grid."""
    bounds = request.bounds or Bounds(
        lat_min=settings.bounds_lat_min,
        lat_max=settings.bounds_lat_max,
        lon_min=settings.bounds_lon_min,
        lon_max=settings.bounds_lon_max,
    )
    grid_coordinates = coordinate_lattice(bounds, request.grid_x, request.grid_y)

    try:
        stations = await client.forecast_points(
            station_lattice(bounds), request.hour_index
        )
        elevations = await client.elevations(grid_coordinates)
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Upstream weather or elevation request failed: {exc}",
        ) from exc

    cells = predict_grid(
        bounds=bounds,
        grid_x=request.grid_x,
        grid_y=request.grid_y,
        elevations=elevations,
        stations=stations,
        field=request.field,
        elevation_weight=request.elevation_weight,
        idw_power=request.idw_power,
    )
    values = [cell.value for cell in cells]
    units = {
        "temperature_2m": "°C",
        "precipitation": "mm",
        "wind_speed_10m": "km/h",
    }

    return ForecastGridResponse(
        time=stations[0].time,
        field=request.field,
        unit=units[request.field],
        bounds=bounds,
        grid_x=request.grid_x,
        grid_y=request.grid_y,
        values=values,
        min_value=min(values),
        max_value=max(values),
        stations=[
            StationObservation(
                latitude=station.latitude,
                longitude=station.longitude,
                elevation=station.elevation,
                value=station.values[request.field],
            )
            for station in stations
        ],
        method=(
            "Elevation-aware inverse-distance weighted residual interpolation; "
            "temperature includes a 6.5°C/km lapse-rate baseline."
        ),
    )
