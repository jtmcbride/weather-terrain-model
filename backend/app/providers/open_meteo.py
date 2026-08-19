from dataclasses import dataclass
import asyncio

import httpx

FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
ELEVATION_URL = "https://api.open-meteo.com/v1/elevation"
ELEVATION_BATCH_SIZE = 100


@dataclass(frozen=True)
class ForecastPoint:
    latitude: float
    longitude: float
    elevation: float
    time: str
    values: dict[str, float]


class OpenMeteoClient:
    """Minimal async client for weather forecasts and terrain elevation."""

    def __init__(self, timeout_seconds: float = 30.0) -> None:
        self.timeout_seconds = timeout_seconds

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

    async def forecast_point(
        self, latitude: float, longitude: float, hour_index: int
    ) -> ForecastPoint:
        params = {
            "latitude": latitude,
            "longitude": longitude,
            "hourly": "temperature_2m,precipitation,wind_speed_10m",
            "forecast_days": 7,
            "timezone": "UTC",
        }
        async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
            response = await client.get(FORECAST_URL, params=params)
            response.raise_for_status()
        payload = response.json()
        hourly = payload["hourly"]
        index = min(hour_index, len(hourly["time"]) - 1)
        return ForecastPoint(
            latitude=float(payload["latitude"]),
            longitude=float(payload["longitude"]),
            elevation=float(payload.get("elevation", 0.0)),
            time=str(hourly["time"][index]),
            values={
                "temperature_2m": float(hourly["temperature_2m"][index]),
                "precipitation": float(hourly["precipitation"][index]),
                "wind_speed_10m": float(hourly["wind_speed_10m"][index]),
            },
        )

    async def forecast_points(
        self, coordinates: list[tuple[float, float]], hour_index: int
    ) -> list[ForecastPoint]:
        return await asyncio.gather(
            *(self.forecast_point(latitude, longitude, hour_index) for latitude, longitude in coordinates)
        )
