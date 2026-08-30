from dataclasses import dataclass, field
import asyncio

import httpx

FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
ELEVATION_URL = "https://api.open-meteo.com/v1/elevation"
ELEVATION_BATCH_SIZE = 100
FORECAST_BATCH_SIZE = 50

# Always requested. Every model Open-Meteo serves carries these.
CORE_SURFACE_VARIABLES = (
    "temperature_2m",
    "precipitation",
    "wind_speed_10m",
    "wind_direction_10m",
    "relative_humidity_2m",
    "dew_point_2m",
    "cloud_cover_low",
)

# Requested but not depended on: `visibility` is only published by some models
# (NOAA GFS/HRRR and DWD ICON carry it, others do not) and `boundary_layer_height`
# is similarly model-dependent. If the upstream rejects them or returns nulls,
# `fog.py` falls back to the dewpoint-depression diagnosis instead.
OPTIONAL_SURFACE_VARIABLES = (
    "visibility",
    "boundary_layer_height",
)

# Pressure levels used to locate the subsidence inversion that caps the marine
# layer. 1000-850 hPa spans roughly 100-1500 m, which brackets every fog top
# the Bay Area produces.
PRESSURE_LEVELS = (1000, 950, 925, 900, 850)


def _level_variables() -> tuple[str, ...]:
    names: list[str] = []
    for level in PRESSURE_LEVELS:
        names.append(f"temperature_{level}hPa")
        names.append(f"geopotential_height_{level}hPa")
    return tuple(names)


PRESSURE_VARIABLES = _level_variables()


@dataclass(frozen=True)
class LevelSample:
    """A single pressure level at one point and hour."""

    pressure_hpa: int
    temperature_c: float
    height_m: float


@dataclass(frozen=True)
class ForecastPoint:
    latitude: float
    longitude: float
    elevation: float
    time: str
    values: dict[str, float]
    levels: tuple[LevelSample, ...] = ()
    missing: tuple[str, ...] = field(default=())


def _maybe_float(series: list | None, index: int) -> float | None:
    if not series or index >= len(series):
        return None
    value = series[index]
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


class OpenMeteoClient:
    """Minimal async client for weather forecasts and terrain elevation."""

    def __init__(self, timeout_seconds: float = 30.0) -> None:
        self.timeout_seconds = timeout_seconds

    # ------------------------------------------------------------------
    # Elevation
    # ------------------------------------------------------------------

    async def _elevations_batch(
        self, client: httpx.AsyncClient, coordinates: list[tuple[float, float]]
    ) -> list[float]:
        params = {
            "latitude": ",".join(f"{lat:.5f}" for lat, _ in coordinates),
            "longitude": ",".join(f"{lon:.5f}" for _, lon in coordinates),
        }
        response = await client.get(ELEVATION_URL, params=params)
        response.raise_for_status()
        payload = response.json()
        return [float(value) for value in payload["elevation"]]

    async def elevations(self, coordinates: list[tuple[float, float]]) -> list[float]:
        """Fetch elevation for an arbitrary number of coordinate pairs.

        The upstream Open-Meteo elevation endpoint limits each request to
        ELEVATION_BATCH_SIZE coordinates and also enforces a max URI length,
        so larger coordinate lists are split into sequential batches and
        fetched concurrently, preserving input order.

        Prefer ``providers.dem.DemProvider`` for render paths: it caches to
        disk so a grid is only ever fetched once.
        """
        if not coordinates:
            return []
        batches = [
            coordinates[i : i + ELEVATION_BATCH_SIZE]
            for i in range(0, len(coordinates), ELEVATION_BATCH_SIZE)
        ]
        async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
            results = await asyncio.gather(
                *(self._elevations_batch(client, batch) for batch in batches)
            )
        elevations: list[float] = []
        for batch_result in results:
            elevations.extend(batch_result)
        return elevations

    # ------------------------------------------------------------------
    # Forecasts
    # ------------------------------------------------------------------

    def _parse_location(
        self,
        location: dict,
        hour_index: int,
        requested: tuple[str, ...],
        want_levels: bool,
    ) -> ForecastPoint:
        hourly = location.get("hourly") or {}
        times = hourly.get("time") or []
        if not times:
            raise ValueError("Upstream forecast contained no hourly series")
        index = min(hour_index, len(times) - 1)

        values: dict[str, float] = {}
        missing: list[str] = []
        for name in requested:
            parsed = _maybe_float(hourly.get(name), index)
            if parsed is None:
                missing.append(name)
            else:
                values[name] = parsed

        levels: list[LevelSample] = []
        if want_levels:
            for level in PRESSURE_LEVELS:
                temperature = _maybe_float(hourly.get(f"temperature_{level}hPa"), index)
                height = _maybe_float(
                    hourly.get(f"geopotential_height_{level}hPa"), index
                )
                if temperature is None or height is None:
                    continue
                levels.append(
                    LevelSample(
                        pressure_hpa=level, temperature_c=temperature, height_m=height
                    )
                )
            levels.sort(key=lambda sample: sample.height_m)

        return ForecastPoint(
            latitude=float(location["latitude"]),
            longitude=float(location["longitude"]),
            elevation=float(location.get("elevation", 0.0)),
            time=str(times[index]),
            values=values,
            levels=tuple(levels),
            missing=tuple(missing),
        )

    async def _forecast_batch(
        self,
        client: httpx.AsyncClient,
        coordinates: list[tuple[float, float]],
        hour_index: int,
        variables: tuple[str, ...],
        want_levels: bool,
    ) -> list[ForecastPoint]:
        params = {
            "latitude": ",".join(f"{lat:.5f}" for lat, _ in coordinates),
            "longitude": ",".join(f"{lon:.5f}" for _, lon in coordinates),
            "hourly": ",".join(variables),
            "forecast_days": 7,
            "timezone": "UTC",
        }
        response = await client.get(FORECAST_URL, params=params)
        response.raise_for_status()
        payload = response.json()
        # Open-Meteo returns a bare object for one coordinate and a list for many.
        locations = payload if isinstance(payload, list) else [payload]
        return [
            self._parse_location(location, hour_index, variables, want_levels)
            for location in locations
        ]

    async def forecast_points(
        self,
        coordinates: list[tuple[float, float]],
        hour_index: int,
        include_optional: bool = False,
        include_levels: bool = False,
    ) -> list[ForecastPoint]:
        """Fetch hourly forecasts for many points in as few requests as possible.

        Open-Meteo accepts comma-separated coordinate lists, so N points cost
        ceil(N / FORECAST_BATCH_SIZE) requests rather than N. One client is
        reused across all of them.

        If the upstream rejects the optional variables (they are model-dependent),
        the request is retried once with only the core set, and the dropped names
        are reported on each point's ``missing`` tuple.
        """
        if not coordinates:
            return []

        variables = CORE_SURFACE_VARIABLES
        if include_optional:
            variables = variables + OPTIONAL_SURFACE_VARIABLES
        if include_levels:
            variables = variables + PRESSURE_VARIABLES

        batches = [
            coordinates[i : i + FORECAST_BATCH_SIZE]
            for i in range(0, len(coordinates), FORECAST_BATCH_SIZE)
        ]

        async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
            try:
                results = await asyncio.gather(
                    *(
                        self._forecast_batch(
                            client, batch, hour_index, variables, include_levels
                        )
                        for batch in batches
                    )
                )
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code != 400 or variables == CORE_SURFACE_VARIABLES:
                    raise
                # A variable this model does not publish. Drop the optional set
                # and retry with what every model carries.
                dropped = tuple(
                    name for name in variables if name not in CORE_SURFACE_VARIABLES
                )
                results = await asyncio.gather(
                    *(
                        self._forecast_batch(
                            client, batch, hour_index, CORE_SURFACE_VARIABLES, False
                        )
                        for batch in batches
                    )
                )
                results = [
                    [
                        ForecastPoint(
                            latitude=point.latitude,
                            longitude=point.longitude,
                            elevation=point.elevation,
                            time=point.time,
                            values=point.values,
                            levels=point.levels,
                            missing=point.missing + dropped,
                        )
                        for point in batch
                    ]
                    for batch in results
                ]

        points: list[ForecastPoint] = []
        for batch_result in results:
            points.extend(batch_result)
        return points

    async def forecast_point(
        self, latitude: float, longitude: float, hour_index: int
    ) -> ForecastPoint:
        points = await self.forecast_points([(latitude, longitude)], hour_index)
        return points[0]
