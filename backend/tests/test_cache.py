"""The cache exists to keep the live upstreams *available*, not just fast.

Both Open-Meteo and the AWC rate limit anonymous callers, and the fog client
scrubs a 168-hour timeline. These tests pin the three properties that keep a
drag of the hour slider from turning into a 429.
"""

import asyncio

import httpx
import pytest

from app.core.cache import TtlCache
from app.providers.metar import MetarClient
from app.providers.open_meteo import OpenMeteoClient


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


async def test_a_fresh_entry_is_served_without_calling_the_factory():
    clock = FakeClock()
    cache: TtlCache[int] = TtlCache(ttl_seconds=10.0, clock=clock)
    calls = 0

    async def factory() -> int:
        nonlocal calls
        calls += 1
        return calls

    assert await cache.get_or_fetch("k", factory) == 1
    assert await cache.get_or_fetch("k", factory) == 1
    clock.advance(11.0)
    assert await cache.get_or_fetch("k", factory) == 2
    assert calls == 2


async def test_concurrent_misses_make_one_upstream_call():
    """Single flight. Without it, the animation loop is the rate-limit burst."""
    cache: TtlCache[int] = TtlCache(ttl_seconds=60.0)
    calls = 0
    release = asyncio.Event()

    async def factory() -> int:
        nonlocal calls
        calls += 1
        await release.wait()
        return calls

    waiters = [asyncio.create_task(cache.get_or_fetch("k", factory)) for _ in range(8)]
    await asyncio.sleep(0)
    release.set()
    results = await asyncio.gather(*waiters)

    assert calls == 1
    assert results == [1] * 8


async def test_an_expired_entry_is_served_when_the_refresh_fails():
    """A stale forecast beats a 502; the response can say so in `warnings`."""
    clock = FakeClock()
    cache: TtlCache[str] = TtlCache(ttl_seconds=5.0, clock=clock)

    async def good() -> str:
        return "payload"

    async def bad() -> str:
        raise httpx.ConnectError("upstream down")

    assert await cache.get_or_fetch("k", good) == "payload"
    clock.advance(60.0)
    assert await cache.get_or_fetch("k", bad) == "payload"
    assert cache.stats()["stale_serves"] == 1


async def test_a_first_fetch_failure_still_raises():
    cache: TtlCache[str] = TtlCache(ttl_seconds=5.0)

    async def bad() -> str:
        raise httpx.ConnectError("upstream down")

    with pytest.raises(httpx.ConnectError):
        await cache.get_or_fetch("k", bad)


async def test_the_cache_evicts_the_oldest_entry_past_its_cap():
    cache: TtlCache[int] = TtlCache(ttl_seconds=60.0, max_entries=2)

    for key in ("a", "b", "c"):
        await cache.get_or_fetch(key, _constant(1))

    assert cache.peek("a") is None
    assert cache.peek("b") == 1
    assert cache.peek("c") == 1


def _constant(value):
    async def factory():
        return value

    return factory


# ----------------------------------------------------------------------
# Provider-level: the property that actually removes the 429
# ----------------------------------------------------------------------


def _hourly_payload(hours: int = 48) -> list[dict]:
    return [
        {
            "latitude": 37.7,
            "longitude": -122.4,
            "elevation": 12.0,
            "hourly": {
                "time": [f"2026-09-05T{hour % 24:02d}:00" for hour in range(hours)],
                "temperature_2m": [15.0 + hour * 0.01 for hour in range(hours)],
                "precipitation": [0.0] * hours,
                "wind_speed_10m": [10.0] * hours,
                "wind_direction_10m": [270.0] * hours,
                "relative_humidity_2m": [90.0] * hours,
                "dew_point_2m": [13.0] * hours,
                "cloud_cover_low": [80.0] * hours,
            },
        }
    ]


async def test_every_hour_of_the_timeline_costs_one_forecast_request(monkeypatch):
    """One Open-Meteo response covers the whole window, so scrubbing is free.

    This is the difference between a timeline drag costing 1 upstream request
    and costing 168 of them.
    """
    client = OpenMeteoClient(cache_ttl_seconds=900.0)
    requests = 0

    async def fake_get(self, url, params=None):
        nonlocal requests
        requests += 1
        return httpx.Response(
            200, json=_hourly_payload(), request=httpx.Request("GET", url)
        )

    monkeypatch.setattr(httpx.AsyncClient, "get", fake_get)

    times = []
    for hour in range(24):
        points = await client.forecast_points([(37.7, -122.4)], hour_index=hour)
        times.append(points[0].time)

    assert requests == 1
    assert len(set(times)) == 24  # each hour really did resolve differently


async def test_a_different_variable_set_is_a_different_cache_entry(monkeypatch):
    client = OpenMeteoClient(cache_ttl_seconds=900.0)
    requests = 0

    async def fake_get(self, url, params=None):
        nonlocal requests
        requests += 1
        return httpx.Response(
            200, json=_hourly_payload(), request=httpx.Request("GET", url)
        )

    monkeypatch.setattr(httpx.AsyncClient, "get", fake_get)

    await client.forecast_points([(37.7, -122.4)], 0)
    await client.forecast_points([(37.7, -122.4)], 0, include_optional=True)
    assert requests == 2


async def test_metar_observations_are_cached_between_requests(monkeypatch):
    client = MetarClient("https://example.invalid/metar", cache_ttl_seconds=300.0)
    requests = 0
    record = {
        "icaoId": "KSFO",
        "lat": 37.62,
        "lon": -122.37,
        "elev": 3.0,
        "reportTime": "2026-09-05 15:56",
        "temp": 14.0,
        "dewp": 13.0,
        "visib": "1/2",
        "rawOb": "KSFO 051556Z 27008KT 1/2SM FG OVC002 14/13",
        "clouds": [{"cover": "OVC", "base": 200}],
    }

    async def fake_get(self, url, params=None):
        nonlocal requests
        requests += 1
        return httpx.Response(
            200, json=[record], request=httpx.Request("GET", url)
        )

    monkeypatch.setattr(httpx.AsyncClient, "get", fake_get)

    first = await client.observations(["KSFO"])
    second = await client.observations(["KSFO"])

    assert requests == 1
    assert first == second
    assert first[0].reports_fog is True
    assert client.cached_age_seconds(["KSFO"]) is not None
