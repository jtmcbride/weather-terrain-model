# Terrain-Aware Weather Model

A production-oriented starter for rendering real hourly weather forecasts across Northern California with **elevation-aware interpolation**.

## Initial architecture

- **Forecast provider:** Open-Meteo hourly temperature, precipitation, and wind forecasts.
- **Terrain provider:** Elevation samples from the Open-Meteo elevation endpoint (Copernicus GLO-90 DEM).
- **Interpolation:** inverse-distance weighting (IDW) where distance combines geographic separation and elevation difference.
- **Temperature treatment:** apply a 6.5°C/km lapse-rate trend, interpolate residuals, then add the terrain trend back. This avoids smoothing away major mountain-versus-valley temperature differences.
- **Frontend:** Leaflet map plus Canvas raster layer for smoothly animated, gradient-interpolated forecast cells.

## Target API

```http
POST /v1/forecast-grid
Content-Type: application/json

{
  "field": "temperature_2m",
  "hour_index": 0,
  "grid_x": 48,
  "grid_y": 36,
  "elevation_weight": 0.62,
  "idw_power": 2.4
}
```

The API will return a row-major grid, its bounds, observation points, units, and method metadata.

## Development plan

1. Create a FastAPI service with Open-Meteo adapters and a forecast-grid endpoint.
2. Generate per-cell elevation features and elevation-aware IDW residual grids.
3. Add the interactive map client with a 48-hour timeline.
4. Add historical NOAA/Mesonet data and spatial cross-validation.
5. Train a residual model using elevation, slope, aspect, ruggedness, land cover, latitude/longitude, and coastal distance; compare it against IDW/kriging baselines.

## Local workflow

```bash
# Planned commands once the backend and frontend land
docker compose up --build
# Map: http://localhost:8080
# API docs: http://localhost:8000/docs
```

## Status

The repository now contains the project specification and technical design. The next commit will add the runnable backend, Docker configuration, and map interface.
