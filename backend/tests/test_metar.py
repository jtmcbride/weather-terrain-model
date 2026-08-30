from app.providers.metar import (
    parse_metar_payload,
    parse_metar_record,
    parse_visibility_sm,
)


def test_parse_visibility_handles_the_loose_upstream_typing():
    assert parse_visibility_sm(10) == 10.0
    assert parse_visibility_sm(2.5) == 2.5
    assert parse_visibility_sm("10+") == 10.0
    assert parse_visibility_sm("1/2") == 0.5
    assert parse_visibility_sm("1 1/2") == 1.5
    assert parse_visibility_sm(None) is None
    assert parse_visibility_sm("") is None
    assert parse_visibility_sm("garbage") is None


def test_parse_record_converts_units_and_finds_the_ceiling():
    record = {
        "icaoId": "KSFO",
        "lat": 37.6197,
        "lon": -122.3647,
        "elev": 3,
        "reportTime": "2026-08-30 14:56:00",
        "temp": 15.0,
        "dewp": 14.0,
        "wspd": 10,
        "wdir": 270,
        "visib": "1/2",
        "clouds": [{"cover": "FEW", "base": 400}, {"cover": "OVC", "base": 900}],
        "rawOb": "KSFO 301456Z 27010KT 1/2SM FG OVC009 15/14 A2992",
    }
    observation = parse_metar_record(record)

    assert observation is not None
    assert observation.station_id == "KSFO"
    # Half a statute mile.
    assert observation.visibility_m == 0.5 * 1609.344
    # 10 knots in metres per second.
    assert abs(observation.wind_speed_ms - 5.14444) < 1e-4
    # Ceiling is the lowest broken-or-worse layer, converted to feet AGL -> m MSL.
    assert abs(observation.ceiling_m - (900 * 0.3048 + 3)) < 1e-6
    # The FEW layer is lower but is not a ceiling.
    assert abs(observation.lowest_cloud_base_m - (400 * 0.3048 + 3)) < 1e-6
    assert observation.low_cloud_fraction == 1.0
    assert observation.reports_fog is True
    assert observation.dew_point_depression_c == 1.0


def test_scattered_cloud_is_not_a_ceiling():
    record = {
        "icaoId": "KOAK",
        "lat": 37.72,
        "lon": -122.22,
        "elev": 2,
        "visib": 10,
        "clouds": [{"cover": "SCT", "base": 2500}],
        "rawOb": "KOAK 301453Z 28008KT 10SM SCT025 21/12 A2990",
    }
    observation = parse_metar_record(record)

    assert observation is not None
    assert observation.ceiling_m is None
    assert observation.lowest_cloud_base_m is not None
    assert observation.reports_fog is False


def test_mist_is_not_reported_as_fog():
    record = {
        "icaoId": "KHAF",
        "lat": 37.5134,
        "lon": -122.5011,
        "elev": 20,
        "visib": 4,
        "clouds": [],
        "rawOb": "KHAF 301453Z 30006KT 4SM BR CLR 14/13 A2991",
    }
    observation = parse_metar_record(record)

    assert observation is not None
    assert observation.reports_fog is False


def test_records_without_position_are_skipped():
    assert parse_metar_record({"icaoId": "KXXX", "visib": 10}) is None
    payload = [
        {"icaoId": "KXXX", "visib": 10},
        {"icaoId": "KSFO", "lat": 37.6, "lon": -122.4, "elev": 3, "visib": 10},
        "not a record",
    ]
    assert [o.station_id for o in parse_metar_payload(payload)] == ["KSFO"]


def test_parse_payload_rejects_non_lists():
    assert parse_metar_payload({"error": "nope"}) == []
