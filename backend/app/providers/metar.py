"""METAR surface observations from the NOAA Aviation Weather Center.

The forecast lattice the grid builder used before this module is a set of
*model* samples, not observations, so it can never show the fog edge the
hills actually produce -- the models it comes from run at 2-11 km. METARs are
real instruments, they report visibility and sky condition directly, and they
are free and unauthenticated.

KHAF (Half Moon Bay, ocean side) versus KSFO (bay side) is the canonical pair
that disagrees whenever the peninsula hills are holding fog on the west.
"""

from dataclasses import dataclass
import re

import httpx

STATUTE_MILE_M = 1609.344
FOOT_M = 0.3048
KNOT_MS = 0.514444

# Octas implied by each METAR sky-cover code, as a fraction.
COVER_FRACTION: dict[str, float] = {
    "SKC": 0.0,
    "CLR": 0.0,
    "NCD": 0.0,
    "NSC": 0.0,
    "CAVOK": 0.0,
    "FEW": 0.1875,
    "SCT": 0.4375,
    "BKN": 0.6875,
    "OVC": 1.0,
    "OVX": 1.0,
    "VV": 1.0,
}

# Covers that constitute a ceiling, i.e. a deck rather than scattered cloud.
CEILING_COVERS = frozenset({"BKN", "OVC", "OVX", "VV"})

# Present-weather groups that mean obscuration at the surface.
FOG_PRESENT_WEATHER = re.compile(r"\b(?:[-+]?(?:MI|BC|PR|FZ)?FG|BR|HZ)\b")
DENSE_FOG_PRESENT_WEATHER = re.compile(r"\b(?:[-+]?(?:MI|BC|PR|FZ)?FG)\b")


@dataclass(frozen=True)
class MetarObservation:
    station_id: str
    latitude: float
    longitude: float
    elevation_m: float
    observed_at: str
    temperature_c: float | None = None
    dew_point_c: float | None = None
    visibility_m: float | None = None
    wind_speed_ms: float | None = None
    wind_direction_deg: float | None = None
    # Both in metres above mean sea level, not above ground.
    ceiling_m: float | None = None
    lowest_cloud_base_m: float | None = None
    low_cloud_fraction: float | None = None
    reports_fog: bool = False
    raw: str = ""

    @property
    def dew_point_depression_c(self) -> float | None:
        if self.temperature_c is None or self.dew_point_c is None:
            return None
        return self.temperature_c - self.dew_point_c


def parse_visibility_sm(value: object) -> float | None:
    """Parse the AWC ``visib`` field into statute miles.

    The field is loosely typed upstream: it arrives as a number, as ``"10+"``
    for unrestricted visibility, or as a fraction like ``"1/2"`` or ``"1 1/2"``.
    """
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)

    text = str(value).strip().rstrip("+").replace("M", "").strip()
    if not text:
        return None
    total = 0.0
    for part in text.split():
        if "/" in part:
            numerator, _, denominator = part.partition("/")
            try:
                total += float(numerator) / float(denominator)
            except (ValueError, ZeroDivisionError):
                return None
        else:
            try:
                total += float(part)
            except ValueError:
                return None
    return total


def _maybe_float(value: object) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_metar_record(record: dict) -> MetarObservation | None:
    """Convert one AWC JSON record into a normalized observation.

    Returns ``None`` when the record lacks the position or elevation the
    terrain model needs, rather than guessing.
    """
    latitude = _maybe_float(record.get("lat"))
    longitude = _maybe_float(record.get("lon"))
    elevation = _maybe_float(record.get("elev"))
    station_id = record.get("icaoId") or record.get("station_id")
    if latitude is None or longitude is None or elevation is None or not station_id:
        return None

    visibility_sm = parse_visibility_sm(record.get("visib"))
    visibility_m = visibility_sm * STATUTE_MILE_M if visibility_sm is not None else None

    ceiling_m: float | None = None
    lowest_base_m: float | None = None
    low_cloud_fraction: float | None = None

    clouds = record.get("clouds") or []
    if isinstance(clouds, list):
        for layer in clouds:
            if not isinstance(layer, dict):
                continue
            cover = str(layer.get("cover") or "").upper()
            fraction = COVER_FRACTION.get(cover)
            if fraction is not None:
                low_cloud_fraction = max(low_cloud_fraction or 0.0, fraction)
            base_ft = _maybe_float(layer.get("base"))
            if base_ft is None:
                continue
            base_msl = base_ft * FOOT_M + elevation
            if lowest_base_m is None or base_msl < lowest_base_m:
                lowest_base_m = base_msl
            if cover in CEILING_COVERS and (ceiling_m is None or base_msl < ceiling_m):
                ceiling_m = base_msl

    raw = str(record.get("rawOb") or "")
    wind_speed_kt = _maybe_float(record.get("wspd"))

    return MetarObservation(
        station_id=str(station_id),
        latitude=latitude,
        longitude=longitude,
        elevation_m=elevation,
        observed_at=str(record.get("reportTime") or record.get("obsTime") or ""),
        temperature_c=_maybe_float(record.get("temp")),
        dew_point_c=_maybe_float(record.get("dewp")),
        visibility_m=visibility_m,
        wind_speed_ms=wind_speed_kt * KNOT_MS if wind_speed_kt is not None else None,
        wind_direction_deg=_maybe_float(record.get("wdir")),
        ceiling_m=ceiling_m,
        lowest_cloud_base_m=lowest_base_m,
        low_cloud_fraction=low_cloud_fraction,
        reports_fog=bool(DENSE_FOG_PRESENT_WEATHER.search(raw)),
        raw=raw,
    )


def parse_metar_payload(payload: object) -> list[MetarObservation]:
    """Parse a full AWC response, skipping records that cannot be used."""
    if not isinstance(payload, list):
        return []
    observations: list[MetarObservation] = []
    for record in payload:
        if not isinstance(record, dict):
            continue
        parsed = parse_metar_record(record)
        if parsed is not None:
            observations.append(parsed)
    return observations


class MetarClient:
    """Fetches current METARs for a fixed set of station IDs."""

    def __init__(self, url: str, timeout_seconds: float = 30.0) -> None:
        self.url = url
        self.timeout_seconds = timeout_seconds

    async def observations(
        self, station_ids: list[str], max_age_minutes: int = 90
    ) -> list[MetarObservation]:
        if not station_ids:
            return []
        params = {
            "ids": ",".join(station_ids),
            "format": "json",
            "hours": max(1, round(max_age_minutes / 60)),
        }
        async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
            response = await client.get(self.url, params=params)
            response.raise_for_status()
            payload = response.json()

        # The API returns every observation inside the window; keep the most
        # recent one per station.
        latest: dict[str, MetarObservation] = {}
        for observation in parse_metar_payload(payload):
            existing = latest.get(observation.station_id)
            if existing is None or observation.observed_at >= existing.observed_at:
                latest[observation.station_id] = observation
        return list(latest.values())
