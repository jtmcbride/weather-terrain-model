import asyncio
import logging
import time
from datetime import datetime, timezone

import numpy as np
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import settings
from app.features.fog import (
    diagnose_slab,
    observed_fog_fraction,
    override_slab_top,
)
from app.providers.dem import DemProvider
from app.providers.metar import MetarClient
from app.providers.open_meteo import (
    OPTIONAL_SURFACE_VARIABLES,
    ForecastPoint,
    OpenMeteoClient,
)
from app.schemas import (
    FIELD_UNITS,
    Bounds,
    FogGridRequest,
    FogGridResponse,
    FogStation,
    ForecastGridResponse,
    GridRequest,
    SlabProfile,
    SourceStatus,
    SourceStatusResponse,
    StationObservation,
)
from app.services.fog_model import FogStationInput, build_fog_grid
from app.services.grid_builder import coordinate_lattice, predict_grid, station_lattice

logger = logging.getLogger(__name__)

app = FastAPI(title=settings.app_name, version="0.2.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_allow_origins,
    allow_origin_regex=settings.cors_allow_origin_regex,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

client = OpenMeteoClient(
    settings.request_timeout_seconds,
    cache_ttl_seconds=settings.forecast_cache_ttl_seconds,
)
metar_client = MetarClient(
    settings.metar_url,
    settings.request_timeout_seconds,
    cache_ttl_seconds=settings.metar_cache_ttl_seconds,
)
dem = DemProvider(
    cache_dir=settings.dem_cache_dir,
    raster_path=settings.dem_raster_path,
    fetcher=client.elevations,
)

KMH_TO_MS = 1000.0 / 3600.0


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get(f"{settings.api_prefix}/sources", response_model=SourceStatusResponse)
async def sources() -> SourceStatusResponse:
    """Probe the live upstreams and report what the model can actually see.

    ``/health`` answers "is this process up". This answers the question that
    actually matters for a live weather model: is real data arriving right now,
    how old is it, and if not, which fallback is in play. Both probes are run
    concurrently and neither can fail the request -- a dead upstream is
    reported as a degraded source, not as a 5xx, for the same reason the
    fog-grid response carries `warnings` rather than raising.
    """
    sample = station_lattice(
        Bounds(
            lat_min=settings.fog_bounds_lat_min,
            lat_max=settings.fog_bounds_lat_max,
            lon_min=settings.fog_bounds_lon_min,
            lon_max=settings.fog_bounds_lon_max,
        ),
        columns=2,
        rows=2,
    )

    async def probe_forecast() -> SourceStatus:
        started = time.perf_counter()
        try:
            points = await client.forecast_points(
                sample, hour_index=0, include_optional=True, include_levels=True
            )
        except Exception as exc:
            return SourceStatus(
                name="open-meteo",
                ok=False,
                detail=f"{type(exc).__name__}: {exc}",
                cache=client.cache_stats,
            )
        missing = sorted({name for point in points for name in point.missing})
        levels = sum(len(point.levels) for point in points)
        return SourceStatus(
            name="open-meteo",
            ok=bool(points),
            latency_ms=round((time.perf_counter() - started) * 1000, 1),
            valid_time=points[0].time if points else None,
            sample_count=len(points),
            missing_variables=missing,
            detail=(
                f"{levels} pressure-level samples across {len(points)} points"
                + (f"; upstream omitted {', '.join(missing)}" if missing else "")
            ),
            cache=client.cache_stats,
        )

    async def probe_metar() -> SourceStatus:
        if not settings.use_metar_observations:
            return SourceStatus(
                name="metar",
                ok=False,
                detail="Disabled by configuration (use_metar_observations=false).",
            )
        started = time.perf_counter()
        try:
            observations = await metar_client.observations(
                settings.metar_station_ids, settings.metar_max_age_minutes
            )
        except Exception as exc:
            return SourceStatus(
                name="metar",
                ok=False,
                detail=f"{type(exc).__name__}: {exc}",
                cache=metar_client.cache_stats,
            )
        latest = max((obs.observed_at for obs in observations), default=None)
        reporting = sorted(obs.station_id for obs in observations)
        silent = sorted(set(settings.metar_station_ids) - set(reporting))
        return SourceStatus(
            name="metar",
            ok=bool(observations),
            latency_ms=round((time.perf_counter() - started) * 1000, 1),
            valid_time=latest,
            sample_count=len(observations),
            stations=reporting,
            detail=(
                f"{len(reporting)} of {len(settings.metar_station_ids)} stations "
                "reporting"
                + (f"; silent: {', '.join(silent)}" if silent else "")
            ),
            cache=metar_client.cache_stats,
        )

    forecast_status, metar_status = await asyncio.gather(
        probe_forecast(), probe_metar()
    )
    return SourceStatusResponse(
        checked_at=datetime.now(timezone.utc).isoformat(timespec="seconds"),
        live=forecast_status.ok,
        sources=[forecast_status, metar_status],
    )


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
            station_lattice(bounds),
            request.hour_index,
            include_optional=request.field in OPTIONAL_SURFACE_VARIABLES,
        )
        elevations = await client.elevations(grid_coordinates)
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Upstream weather or elevation request failed: {exc}",
        ) from exc

    usable = [station for station in stations if request.field in station.values]
    if not usable:
        raise HTTPException(
            status_code=422,
            detail=(
                f"The upstream model did not return '{request.field}' for any "
                "sample point. This variable is model-dependent; try another field."
            ),
        )

    cells = predict_grid(
        bounds=bounds,
        grid_x=request.grid_x,
        grid_y=request.grid_y,
        elevations=elevations,
        stations=usable,
        field=request.field,
        elevation_weight=request.elevation_weight,
        idw_power=request.idw_power,
    )
    values = [cell.value for cell in cells]

    return ForecastGridResponse(
        time=usable[0].time,
        field=request.field,
        unit=FIELD_UNITS[request.field],
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
            for station in usable
        ],
        method=(
            "Elevation-aware inverse-distance weighted residual interpolation; "
            "temperature includes a 6.5°C/km lapse-rate baseline."
        ),
    )


def _forecast_fog_station(point: ForecastPoint) -> FogStationInput:
    temperature = point.values.get("temperature_2m")
    dew_point = point.values.get("dew_point_2m")
    depression = (
        temperature - dew_point
        if temperature is not None and dew_point is not None
        else None
    )
    low_cloud = point.values.get("cloud_cover_low")
    return FogStationInput(
        source="open-meteo",
        latitude=point.latitude,
        longitude=point.longitude,
        elevation=point.elevation,
        visibility_m=point.values.get("visibility"),
        relative_humidity=point.values.get("relative_humidity_2m"),
        dew_point_depression_c=depression,
        cloud_base_m=None,
        fog_fraction=observed_fog_fraction(
            visibility_m=point.values.get("visibility"),
            dew_point_depression_c=depression,
            low_cloud_fraction=low_cloud / 100.0 if low_cloud is not None else None,
            fog_visibility_m=settings.fog_visibility_m,
            fog_dew_point_depression_c=settings.fog_dewpoint_depression_c,
        ),
    )


@app.post(f"{settings.api_prefix}/fog-grid", response_model=FogGridResponse)
async def fog_grid(request: FogGridRequest) -> FogGridResponse:
    """Diagnose the marine layer and render it against the terrain.

    Fog is modelled as a slab between a cloud base and an inversion top. The
    horizontal extent of marine air is routed around ridges that stand above
    that top; the vertical extent is cut against the DEM. The visible fog edge
    is the intersection of the two, which is why it follows a hillside contour.
    """
    bounds = request.bounds or Bounds(
        lat_min=settings.fog_bounds_lat_min,
        lat_max=settings.fog_bounds_lat_max,
        lon_min=settings.fog_bounds_lon_min,
        lon_max=settings.fog_bounds_lon_max,
    )
    warnings: list[str] = []

    # A coarse lattice is enough for the sounding and the model surface field;
    # the resolution that matters lives in the DEM, not in the forecast.
    sample_points = station_lattice(bounds, columns=5, rows=5)

    try:
        forecast_points = await client.forecast_points(
            sample_points,
            request.hour_index,
            include_optional=True,
            include_levels=True,
        )
    except Exception as exc:
        raise HTTPException(
            status_code=502, detail=f"Upstream forecast request failed: {exc}"
        ) from exc

    if not forecast_points:
        raise HTTPException(status_code=502, detail="Upstream returned no forecast data")

    missing = set()
    for point in forecast_points:
        missing.update(point.missing)
    if "visibility" in missing:
        warnings.append(
            "The upstream model does not publish 'visibility'; fog was diagnosed "
            "from dewpoint depression and low cloud cover instead."
        )
    if not any(point.levels for point in forecast_points):
        warnings.append(
            "No pressure-level temperatures were returned, so the inversion "
            "could not be located directly."
        )

    try:
        elevation, dem_source = await dem.elevation_grid(
            bounds, request.grid_x, request.grid_y
        )
    except Exception as exc:
        raise HTTPException(
            status_code=502, detail=f"Elevation source failed: {exc}"
        ) from exc

    stations: list[FogStationInput] = [
        _forecast_fog_station(point) for point in forecast_points
    ]

    metar_ceilings: list[float] = []
    if request.use_observations and settings.use_metar_observations:
        try:
            observations = await metar_client.observations(
                settings.metar_station_ids, settings.metar_max_age_minutes
            )
        except Exception as exc:
            logger.warning("METAR fetch failed: %s", exc)
            observations = []
            warnings.append(
                f"Live METAR observations were unavailable ({exc}); the grid is "
                "built from model samples only."
            )
        for observation in observations:
            fraction = observed_fog_fraction(
                visibility_m=observation.visibility_m,
                dew_point_depression_c=observation.dew_point_depression_c,
                low_cloud_fraction=observation.low_cloud_fraction,
                reports_fog=observation.reports_fog,
                fog_visibility_m=settings.fog_visibility_m,
                fog_dew_point_depression_c=settings.fog_dewpoint_depression_c,
            )
            stations.append(
                FogStationInput(
                    source="metar",
                    station_id=observation.station_id,
                    latitude=observation.latitude,
                    longitude=observation.longitude,
                    elevation=observation.elevation_m,
                    visibility_m=observation.visibility_m,
                    dew_point_depression_c=observation.dew_point_depression_c,
                    cloud_base_m=observation.ceiling_m,
                    fog_fraction=fraction,
                )
            )
            if observation.ceiling_m is not None:
                metar_ceilings.append(observation.ceiling_m)

    winds = [
        point.values["wind_speed_10m"] * KMH_TO_MS
        for point in forecast_points
        if point.values.get("wind_speed_10m") is not None
    ]
    slab = diagnose_slab(
        levels_by_point=[point.levels for point in forecast_points],
        surface_values=[point.values for point in forecast_points],
        fogged_station_elevations=[
            station.elevation for station in stations if station.is_fogged
        ],
        observed_ceilings_m=metar_ceilings,
        clear_station_elevations=[
            station.elevation for station in stations if station.fog_fraction < 0.2
        ],
        default_top_m=settings.default_fog_top_m,
        mean_wind_ms=float(np.mean(winds)) if winds else None,
    )
    if request.fog_top_override_m is not None:
        slab = override_slab_top(slab, request.fog_top_override_m)

    try:
        # Dijkstra over ~180,000 cells is half a second of CPU. Running it on
        # the event loop stalls every other request for its duration, which is
        # very visible when the client is dragging a slider.
        result = await asyncio.to_thread(
            build_fog_grid,
            bounds=bounds,
            grid_x=request.grid_x,
            grid_y=request.grid_y,
            elevation=elevation,
            stations=stations,
            slab=slab,
            terrain_routing=request.terrain_routing,
            cost_beta=request.cost_beta,
            cost_scale_m=settings.fog_cost_scale_m,
            block_buffer_m=settings.fog_block_buffer_m,
            idw_power=request.idw_power,
            max_visibility_m=settings.max_visibility_m,
            edge_feather_m=(
                settings.fog_edge_feather_m
                if request.edge_feather_m is None
                else request.edge_feather_m
            ),
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    return FogGridResponse(
        time=forecast_points[0].time,
        bounds=bounds,
        grid_x=request.grid_x,
        grid_y=request.grid_y,
        fog_fraction=[round(value, 4) for value in result.fog_fraction.ravel().tolist()],
        visibility_m=[round(value, 1) for value in result.visibility_m.ravel().tolist()],
        elevation_m=[round(value, 1) for value in result.elevation.ravel().tolist()],
        surface_state=result.surface_state.ravel().tolist(),
        slab=SlabProfile(
            base_m=round(slab.base_m, 1),
            top_m=round(slab.top_m, 1),
            inversion_base_m=slab.inversion_base_m,
            inversion_strength_c=slab.inversion_strength_c,
            lcl_m=slab.lcl_m,
            froude_number=slab.froude_number,
            blocking_regime=slab.blocking_regime,
            source=slab.source,
        ),
        stations=[
            FogStation(
                station_id=station.station_id,
                source=station.source,
                latitude=station.latitude,
                longitude=station.longitude,
                elevation=station.elevation,
                visibility_m=station.visibility_m,
                relative_humidity=station.relative_humidity,
                dew_point_depression_c=station.dew_point_depression_c,
                cloud_base_m=station.cloud_base_m,
                fog_fraction=round(station.fog_fraction, 4),
                is_fogged=station.is_fogged,
            )
            for station in result.used_stations
        ],
        min_elevation=float(np.min(result.elevation)),
        max_elevation=float(np.max(result.elevation)),
        method=f"{result.method} DEM source: {dem_source}.",
        warnings=warnings + result.warnings,
    )
