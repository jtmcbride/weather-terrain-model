"""Endpoint wiring, with both upstreams stubbed.

Network egress to Open-Meteo and aviationweather.gov is not available in the
test environment, so these exercise the request/response contract and the
degradation paths rather than live data.
"""

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app import main
from app.providers.dem import DemProvider
from app.providers.metar import MetarObservation
from app.providers.open_meteo import ForecastPoint, LevelSample
from tests.terrain_fixtures import peninsula

GRID_X, GRID_Y = 60, 40

MARINE_LEVELS = (
    LevelSample(1000, 13.0, 110.0),
    LevelSample(950, 12.4, 300.0),
    LevelSample(925, 18.5, 560.0),
    LevelSample(900, 19.0, 800.0),
)


def _forecast_point(latitude: float, longitude: float, **overrides) -> ForecastPoint:
    values = {
        "temperature_2m": 14.0,
        "precipitation": 0.0,
        "wind_speed_10m": 18.0,
        "wind_direction_10m": 270.0,
        "relative_humidity_2m": 95.0,
        "dew_point_2m": 13.5,
        "cloud_cover_low": 95.0,
        "visibility": 600.0,
    }
    values.update(overrides.pop("values", {}))
    return ForecastPoint(
        latitude=latitude,
        longitude=longitude,
        elevation=overrides.pop("elevation", 20.0),
        time="2026-08-30T15:00",
        values=values,
        levels=overrides.pop("levels", MARINE_LEVELS),
        missing=overrides.pop("missing", ()),
    )


@pytest.fixture
def client(monkeypatch, tmp_path):
    async def fake_forecast_points(coordinates, hour_index, **kwargs):
        return [_forecast_point(lat, lon) for lat, lon in coordinates]

    async def fake_metars(station_ids, max_age_minutes=90):
        return [
            MetarObservation(
                station_id="KHAF",
                latitude=37.5134,
                longitude=-122.5011,
                elevation_m=20.0,
                observed_at="2026-08-30 15:00",
                temperature_c=13.0,
                dew_point_c=13.0,
                visibility_m=400.0,
                ceiling_m=60.0,
                low_cloud_fraction=1.0,
                reports_fog=True,
            ),
            MetarObservation(
                station_id="KSFO",
                latitude=37.6197,
                longitude=-122.3647,
                elevation_m=3.0,
                observed_at="2026-08-30 15:00",
                temperature_c=20.0,
                dew_point_c=11.0,
                visibility_m=16000.0,
                low_cloud_fraction=0.0,
                reports_fog=False,
            ),
        ]

    async def fake_elevations(coordinates):
        if len(coordinates) == GRID_X * GRID_Y:
            return peninsula(GRID_Y, GRID_X).ravel().tolist()
        return [10.0] * len(coordinates)

    monkeypatch.setattr(main.client, "forecast_points", fake_forecast_points)
    monkeypatch.setattr(main.client, "elevations", fake_elevations)
    monkeypatch.setattr(main.metar_client, "observations", fake_metars)
    monkeypatch.setattr(
        main, "dem", DemProvider(cache_dir=str(tmp_path), fetcher=fake_elevations)
    )
    return TestClient(main.app)


def test_health(client):
    assert client.get("/health").json() == {"status": "ok"}


def test_fog_grid_returns_a_complete_field(client):
    response = client.post(
        "/v1/fog-grid", json={"grid_x": GRID_X, "grid_y": GRID_Y, "hour_index": 0}
    )
    assert response.status_code == 200, response.text
    body = response.json()

    cells = GRID_X * GRID_Y
    assert len(body["fog_fraction"]) == cells
    assert len(body["visibility_m"]) == cells
    assert len(body["elevation_m"]) == cells
    assert len(body["surface_state"]) == cells

    assert all(0.0 <= value <= 1.0 for value in body["fog_fraction"])
    assert set(body["surface_state"]) <= {
        "above_deck", "in_fog", "under_deck", "clear"
    }
    assert body["max_elevation"] == pytest.approx(300.0)


def test_the_slab_is_diagnosed_from_the_sounding(client):
    body = client.post(
        "/v1/fog-grid", json={"grid_x": GRID_X, "grid_y": GRID_Y}
    ).json()
    slab = body["slab"]

    # The inversion in MARINE_LEVELS sits at 300 m.
    assert slab["inversion_base_m"] == 300.0
    assert slab["top_m"] >= 300.0
    assert slab["blocking_regime"] in {"blocked", "overtopping"}
    assert slab["froude_number"] is not None


def test_metar_observations_reach_the_station_list(client):
    body = client.post(
        "/v1/fog-grid", json={"grid_x": GRID_X, "grid_y": GRID_Y}
    ).json()

    metars = [s for s in body["stations"] if s["source"] == "metar"]
    by_id = {s["station_id"]: s for s in metars}

    # KHAF is fogged on the coast; KSFO is clear on the bay side.
    assert by_id["KHAF"]["is_fogged"] is True
    assert by_id["KSFO"]["is_fogged"] is False
    assert by_id["KHAF"]["fog_fraction"] > by_id["KSFO"]["fog_fraction"]


def test_the_fog_top_can_be_overridden(client):
    body = client.post(
        "/v1/fog-grid",
        json={"grid_x": GRID_X, "grid_y": GRID_Y, "fog_top_override_m": 150.0},
    ).json()

    assert body["slab"]["top_m"] == 150.0
    assert "overridden" in body["slab"]["source"]

    elevation = np.array(body["elevation_m"])
    fog = np.array(body["fog_fraction"])
    # Nothing above a 150 m lid can be in fog.
    assert fog[elevation > 200.0].max() == 0.0


def test_terrain_routing_can_be_disabled_for_comparison(client):
    routed = client.post(
        "/v1/fog-grid",
        json={"grid_x": GRID_X, "grid_y": GRID_Y, "terrain_routing": True},
    ).json()
    straight = client.post(
        "/v1/fog-grid",
        json={"grid_x": GRID_X, "grid_y": GRID_Y, "terrain_routing": False},
    ).json()

    assert "cost-distance" in routed["method"]
    assert "no terrain routing" in straight["method"]
    assert routed["fog_fraction"] != straight["fog_fraction"]


def test_a_missing_visibility_variable_is_reported_not_fatal(client, monkeypatch):
    async def without_visibility(coordinates, hour_index, **kwargs):
        points = []
        for latitude, longitude in coordinates:
            point = _forecast_point(latitude, longitude, missing=("visibility",))
            values = dict(point.values)
            values.pop("visibility")
            points.append(
                ForecastPoint(
                    latitude=point.latitude,
                    longitude=point.longitude,
                    elevation=point.elevation,
                    time=point.time,
                    values=values,
                    levels=point.levels,
                    missing=("visibility",),
                )
            )
        return points

    monkeypatch.setattr(main.client, "forecast_points", without_visibility)
    response = client.post("/v1/fog-grid", json={"grid_x": GRID_X, "grid_y": GRID_Y})

    assert response.status_code == 200
    assert any(
        "does not publish 'visibility'" in warning
        for warning in response.json()["warnings"]
    )


def test_a_metar_outage_degrades_to_model_samples(client, monkeypatch):
    async def failing(station_ids, max_age_minutes=90):
        raise RuntimeError("aviationweather.gov unreachable")

    monkeypatch.setattr(main.metar_client, "observations", failing)
    response = client.post("/v1/fog-grid", json={"grid_x": GRID_X, "grid_y": GRID_Y})

    assert response.status_code == 200
    body = response.json()
    assert any("METAR" in warning for warning in body["warnings"])
    assert all(station["source"] == "open-meteo" for station in body["stations"])


def test_an_upstream_forecast_failure_is_a_502(client, monkeypatch):
    async def failing(coordinates, hour_index, **kwargs):
        raise RuntimeError("upstream down")

    monkeypatch.setattr(main.client, "forecast_points", failing)
    response = client.post("/v1/fog-grid", json={"grid_x": GRID_X, "grid_y": GRID_Y})

    assert response.status_code == 502
    assert "upstream down" in response.json()["detail"]


def test_grid_bounds_are_validated():
    from fastapi.testclient import TestClient as RawClient

    response = RawClient(main.app).post("/v1/fog-grid", json={"grid_x": 5000})
    assert response.status_code == 422


def test_the_legacy_forecast_grid_still_works(client):
    response = client.post(
        "/v1/forecast-grid",
        json={"field": "temperature_2m", "grid_x": 16, "grid_y": 12},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert len(body["values"]) == 16 * 12
    assert body["unit"] == "°C"


def test_the_legacy_endpoint_serves_the_new_humidity_field(client):
    response = client.post(
        "/v1/forecast-grid",
        json={"field": "relative_humidity_2m", "grid_x": 16, "grid_y": 12},
    )
    assert response.status_code == 200, response.text
    assert response.json()["unit"] == "%"


def test_an_unavailable_field_is_a_clear_422(client, monkeypatch):
    async def no_visibility(coordinates, hour_index, **kwargs):
        return [
            ForecastPoint(
                latitude=lat,
                longitude=lon,
                elevation=10.0,
                time="2026-08-30T15:00",
                values={"temperature_2m": 14.0},
                missing=("visibility",),
            )
            for lat, lon in coordinates
        ]

    monkeypatch.setattr(main.client, "forecast_points", no_visibility)
    response = client.post("/v1/forecast-grid", json={"field": "visibility"})

    assert response.status_code == 422
    assert "model-dependent" in response.json()["detail"]


# ----------------------------------------------------------------------
# /v1/sources -- live data availability
# ----------------------------------------------------------------------


def test_sources_reports_both_upstreams_as_live(client):
    body = client.get("/v1/sources").json()

    assert body["live"] is True
    by_name = {source["name"]: source for source in body["sources"]}
    assert by_name["open-meteo"]["ok"] is True
    assert by_name["open-meteo"]["valid_time"] == "2026-08-30T15:00"
    assert by_name["metar"]["ok"] is True
    assert by_name["metar"]["stations"] == ["KHAF", "KSFO"]


def test_sources_reports_a_dead_upstream_without_failing(client, monkeypatch):
    """A degraded source is data, not a 5xx -- same contract as `warnings`."""

    async def unreachable(*args, **kwargs):
        raise ConnectionError("no route to host")

    monkeypatch.setattr(main.metar_client, "observations", unreachable)
    response = client.get("/v1/sources")

    assert response.status_code == 200
    by_name = {source["name"]: source for source in response.json()["sources"]}
    assert by_name["metar"]["ok"] is False
    assert "no route to host" in by_name["metar"]["detail"]
    # The model can still run on forecast samples alone.
    assert response.json()["live"] is True


def test_sources_names_the_variables_the_upstream_dropped(client, monkeypatch):
    async def without_visibility(coordinates, hour_index, **kwargs):
        return [
            _forecast_point(lat, lon, missing=("visibility",))
            for lat, lon in coordinates
        ]

    monkeypatch.setattr(main.client, "forecast_points", without_visibility)
    body = client.get("/v1/sources").json()

    by_name = {source["name"]: source for source in body["sources"]}
    assert by_name["open-meteo"]["missing_variables"] == ["visibility"]
    assert "visibility" in by_name["open-meteo"]["detail"]


def test_the_edge_feather_is_a_request_level_knob(client):
    """A wider feather softens the fog line, so more cells sit part-fogged."""

    def partial_cells(feather_m: float) -> int:
        body = client.post(
            "/v1/fog-grid",
            json={
                "grid_x": GRID_X,
                "grid_y": GRID_Y,
                "edge_feather_m": feather_m,
            },
        ).json()
        return sum(1 for value in body["fog_fraction"] if 0.02 < value < 0.98)

    assert partial_cells(80.0) > partial_cells(5.0)


# ----------------------------------------------------------------------
# CORS
# ----------------------------------------------------------------------


def _preflight(client, origin: str):
    return client.options(
        "/v1/fog-grid",
        headers={
            "Origin": origin,
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type",
        },
    )


@pytest.mark.parametrize(
    "origin",
    [
        "http://localhost:8080",
        "http://127.0.0.1:8080",   # a *different* origin to a browser
        "http://0.0.0.0:8080",
        "http://[::1]:8080",
        "http://localhost:3000",
        "null",                    # a page opened straight from disk
    ],
)
def test_every_local_spelling_passes_preflight(client, origin):
    """Compose publishes the web container on loopback, and which spelling you
    type is arbitrary. An allowlist naming only one answers `400 Disallowed
    CORS origin`, which in the browser is indistinguishable from a dead API."""
    response = _preflight(client, origin)

    assert response.status_code == 200, response.text
    assert response.headers["access-control-allow-origin"] == origin


@pytest.mark.parametrize(
    "origin",
    [
        "http://evil.example.com",
        "http://localhost.evil.com",     # the anchor has to reject this
        "http://127.0.0.1.evil.com",
    ],
)
def test_a_foreign_origin_is_still_refused(client, origin):
    assert _preflight(client, origin).status_code == 400
