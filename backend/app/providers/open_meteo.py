from dataclasses import dataclass
import asyncio

import httpx

FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
ELEVATION_URL = "https://api.open-meteo.com/v1/elevation"


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

    async def elevations(self, coordinates: list[tuple[float, float]]) -> list[float]:
        """Fetch elevation for up to 100 coordinate pairs in a single request."""
        if not coordinates:
            return []
        params = {
            "latitude": ",".join(f"{lat:.5f}" for lat, _ in coordinates),
            "longitude": ",".join(f"{lon:.5f}" for _, lon in coordinates),
        }
        async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
            response = await client.get(ELEVATION_URL, params=params)
            response.raise_for_status()
        payload = response.json()
        return [float(value) for value in payload["elevation"]]

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
