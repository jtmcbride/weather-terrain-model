"""Marine-layer fog diagnosis.

San Francisco fog is not diffuse haze that spreads until something stops it.
It is a stratus slab of cool saturated marine air lying under a subsidence
inversion, with a base ``B`` and a top ``H``. The inversion is a lid: the layer
does not thin gradually with altitude, it ends.

That matters because the hills doing the blocking sit inside the band where H
lives on a summer day (200-500 m): Twin Peaks 281 m, Mount Sutro 274 m, Mount
Davidson 283 m, the Marin Headlands ridge 280-340 m, Mount Tamalpais 784 m.

So the rule is not "fog diffuses until a hill blocks it". It is:

    fog exists where the terrain is below the fog top and the air is saturated

which makes the fog boundary a *level set* -- the intersection contour of the
H surface with the DEM. A contour of a height surface against terrain is, by
construction, a line that traces the shape of the hill. The way fog pours over
the Marin Headlands and through the Golden Gate is not something added on top
of this model; it is what the model produces.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

GRAVITY = 9.80665
KELVIN = 273.15
# Espy's approximation: the lifting condensation level, in metres above ground,
# is about 125 m per degree of dewpoint depression.
ESPY_COEFFICIENT = 125.0
# Vertical softness of the slab edges. Real inversions are sharp but not
# discontinuous, and a hard step aliases badly against a 100 m DEM.
EDGE_FEATHER_M = 30.0


@dataclass(frozen=True)
class SlabDiagnosis:
    base_m: float
    top_m: float
    inversion_base_m: float | None
    inversion_strength_c: float | None
    lcl_m: float | None
    froude_number: float | None
    blocking_regime: str
    source: str
    warnings: tuple[str, ...] = ()


def smoothstep(edge0: float, edge1: float, values: np.ndarray) -> np.ndarray:
    """Hermite smoothstep, clamped outside the edges."""
    if edge1 == edge0:
        return (values >= edge1).astype(np.float64)
    t = np.clip((values - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def lcl_height_m(temperature_c: float, dew_point_c: float) -> float:
    """Cloud base above ground, by Espy's approximation."""
    return max(0.0, ESPY_COEFFICIENT * (temperature_c - dew_point_c))


def potential_temperature_k(temperature_c: float, pressure_hpa: float) -> float:
    """Potential temperature, referenced to 1000 hPa."""
    return (temperature_c + KELVIN) * (1000.0 / pressure_hpa) ** 0.286


def inversion_base(levels) -> tuple[float, float] | None:
    """Find the lowest temperature inversion in a sounding.

    ``levels`` is an iterable of objects with ``pressure_hpa``,
    ``temperature_c`` and ``height_m``, sorted or not. Returns
    ``(height_m, strength_c)`` for the base of the lowest layer where
    temperature increases with height, or ``None`` if the profile is
    monotonically cooling -- which is the well-mixed, no-marine-layer case.
    """
    samples = sorted(levels, key=lambda level: level.height_m)
    for lower, upper in zip(samples, samples[1:]):
        if upper.temperature_c > lower.temperature_c:
            return lower.height_m, upper.temperature_c - lower.temperature_c
    return None


def inversion_theta_jump(levels) -> float | None:
    """Potential-temperature jump across the lowest inversion, in kelvin."""
    samples = sorted(levels, key=lambda level: level.height_m)
    for lower, upper in zip(samples, samples[1:]):
        if upper.temperature_c > lower.temperature_c:
            return potential_temperature_k(
                upper.temperature_c, upper.pressure_hpa
            ) - potential_temperature_k(lower.temperature_c, lower.pressure_hpa)
    return None


def froude_number(
    wind_speed_ms: float,
    layer_depth_m: float,
    theta_jump_k: float,
    mean_theta_k: float = 288.0,
) -> float | None:
    """Shallow-water Froude number for a capped marine layer.

    ``Fr = U / sqrt(g' h)`` with reduced gravity ``g' = g * dtheta / theta``.
    Below 1 the layer is subcritical and is blocked by, or diverts around, an
    obstacle; above 1 it is supercritical and over-tops it. This is the same
    physics that produces the gap flow and hydraulic jump at the Golden Gate.
    """
    if layer_depth_m <= 0 or theta_jump_k <= 0 or mean_theta_k <= 0:
        return None
    reduced_gravity = GRAVITY * theta_jump_k / mean_theta_k
    denominator = (reduced_gravity * layer_depth_m) ** 0.5
    if denominator <= 0:
        return None
    return wind_speed_ms / denominator


def observed_fog_fraction(
    visibility_m: float | None,
    dew_point_depression_c: float | None,
    low_cloud_fraction: float | None,
    reports_fog: bool = False,
    fog_visibility_m: float = 1000.0,
    clear_visibility_m: float = 10000.0,
    fog_dew_point_depression_c: float = 2.5,
) -> float:
    """Collapse one station's report into a 0-1 surface-fog fraction.

    Visibility is the definition of fog, so it wins when it is available. The
    dewpoint-depression and low-cloud terms are the documented fallback for
    models and stations that do not publish visibility.
    """
    if visibility_m is not None:
        span = max(clear_visibility_m - fog_visibility_m, 1.0)
        fraction = (clear_visibility_m - visibility_m) / span
    else:
        depression_term = 0.0
        if dew_point_depression_c is not None:
            span = max(fog_dew_point_depression_c, 1e-6)
            depression_term = (span - dew_point_depression_c) / span
        cloud_term = low_cloud_fraction if low_cloud_fraction is not None else 0.0
        fraction = 0.6 * depression_term + 0.4 * cloud_term

    fraction = float(np.clip(fraction, 0.0, 1.0))
    if reports_fog:
        fraction = max(fraction, 0.85)
    return fraction


def diagnose_slab(
    levels_by_point: list,
    surface_values: list[dict],
    fogged_station_elevations: list[float],
    observed_ceilings_m: list[float],
    clear_station_elevations: list[float] | None = None,
    default_top_m: float = 300.0,
    mean_wind_ms: float | None = None,
) -> SlabDiagnosis:
    """Estimate the fog slab base and top for the whole domain.

    The top is treated as horizontally uniform. Over a 40 km domain under a
    subsidence inversion that is a good approximation, and it is what keeps the
    fog edge crisp: a spatially smeared top would blur exactly the ridgeline
    contrast this model exists to reproduce.
    """
    warnings: list[str] = []

    # --- top: the inversion base -------------------------------------
    inversion_heights: list[float] = []
    inversion_strengths: list[float] = []
    theta_jumps: list[float] = []
    for levels in levels_by_point:
        if not levels:
            continue
        found = inversion_base(levels)
        if found is None:
            continue
        height, strength = found
        inversion_heights.append(height)
        inversion_strengths.append(strength)
        jump = inversion_theta_jump(levels)
        if jump is not None:
            theta_jumps.append(jump)

    inversion_height: float | None = None
    inversion_strength: float | None = None
    if inversion_heights:
        inversion_height = float(np.median(inversion_heights))
        inversion_strength = float(np.median(inversion_strengths))
        top_m = inversion_height
        source = "inversion base from pressure-level profile"
    else:
        boundary_layer = [
            values["boundary_layer_height"]
            for values in surface_values
            if values.get("boundary_layer_height") is not None
        ]
        if boundary_layer:
            top_m = float(np.median(boundary_layer))
            source = "boundary layer height"
        else:
            top_m = default_top_m
            source = "default marine layer depth"
            warnings.append(
                "No inversion found in the pressure-level profile and no "
                "boundary layer height available; using the configured default "
                "fog top. Check that the upstream model publishes "
                "temperature_*hPa."
            )

    # --- base: cloud base -------------------------------------------
    lcl_values = [
        lcl_height_m(values["temperature_2m"], values["dew_point_2m"])
        for values in surface_values
        if values.get("temperature_2m") is not None
        and values.get("dew_point_2m") is not None
    ]
    lcl = float(np.median(lcl_values)) if lcl_values else None

    if observed_ceilings_m:
        base_m = float(np.median(observed_ceilings_m))
        source += " + observed ceilings"
    elif lcl is not None:
        base_m = lcl
        source += " + LCL"
    else:
        base_m = 0.0

    # --- constrain with observations ---------------------------------
    # A station reporting fog at elevation e proves the slab reaches down to e
    # and up past it. These are hard bounds and they override the model.
    if fogged_station_elevations:
        highest_fogged = max(fogged_station_elevations)
        lowest_fogged = min(fogged_station_elevations)
        if base_m > lowest_fogged:
            base_m = lowest_fogged
            source += " (base lowered to a fogged station)"
        if top_m < highest_fogged + EDGE_FEATHER_M:
            top_m = highest_fogged + EDGE_FEATHER_M
            source += " (top raised to a fogged station)"

    # A clear station *above* the diagnosed top is consistent; a clear station
    # below it only bounds the top if it is elevated, which the airport METAR
    # set rarely is. Applied anyway so denser networks tighten this for free.
    if clear_station_elevations:
        elevated_clear = [
            elevation
            for elevation in clear_station_elevations
            if elevation > base_m + EDGE_FEATHER_M
        ]
        if elevated_clear:
            bound = min(elevated_clear)
            if top_m > bound and (
                not fogged_station_elevations or bound > max(fogged_station_elevations)
            ):
                top_m = bound
                source += " (top lowered to a clear elevated station)"

    if base_m >= top_m:
        # The air condenses higher than the lid, so there is no deck under the
        # inversion at all. That is a real, common state -- a dry, clear day --
        # and the honest answer is an empty slab, not a slab relocated upwards.
        base_m = top_m
        warnings.append(
            "The cloud base is at or above the inversion, so no marine layer "
            "is present; the fog field is empty."
        )

    # --- flow regime --------------------------------------------------
    froude: float | None = None
    regime = "unknown"
    theta_jump = float(np.median(theta_jumps)) if theta_jumps else None
    if mean_wind_ms is not None and theta_jump is not None:
        froude = froude_number(mean_wind_ms, top_m, theta_jump)
        if froude is not None:
            regime = "overtopping" if froude >= 1.0 else "blocked"

    return SlabDiagnosis(
        base_m=float(base_m),
        top_m=float(top_m),
        inversion_base_m=inversion_height,
        inversion_strength_c=inversion_strength,
        lcl_m=lcl,
        froude_number=froude,
        blocking_regime=regime,
        source=source,
        warnings=tuple(warnings),
    )


def override_slab_top(slab: SlabDiagnosis, top_m: float) -> SlabDiagnosis:
    """Re-diagnose the slab with the inversion asserted at ``top_m``.

    This is the "what does the city look like under a 250 m marine layer"
    control, so it has to produce a slab with thickness. Clamping the base to
    ``min(base, top)`` alone does not: on a dry day the diagnosed base sits
    *above* the inversion (there is no deck), and clamping collapses it onto
    the new top, leaving an empty slab and a slider that visibly does nothing.

    When the diagnosed base cannot fit under the asserted top, the base drops
    to the surface -- which is what a marine layer of that depth actually looks
    like at the coast -- and the source string says the scenario is imposed
    rather than observed.
    """
    base_m = min(slab.base_m, top_m)
    source = slab.source + f" (fog top overridden to {top_m:.0f} m by request"
    if base_m >= top_m:
        base_m = 0.0
        source += "; the diagnosed cloud base does not fit under it, so the "
        source += "deck is assumed to reach the surface"
    source += ")"
    return SlabDiagnosis(
        base_m=base_m,
        top_m=top_m,
        inversion_base_m=slab.inversion_base_m,
        inversion_strength_c=slab.inversion_strength_c,
        lcl_m=slab.lcl_m,
        froude_number=slab.froude_number,
        blocking_regime=slab.blocking_regime,
        source=source,
        # The "no marine layer is present" warning is about the *diagnosed*
        # slab, which this call has just replaced.
        warnings=tuple(
            warning for warning in slab.warnings if "no marine layer" not in warning
        ),
    )


def slab_occupancy(
    elevation: np.ndarray, base_m: float, top_m: float, feather_m: float = EDGE_FEATHER_M
) -> np.ndarray:
    """How much of the surface at each cell sits inside the fog slab.

    1 where the ground is between the deck base and the inversion, falling to 0
    above the top and below the base. The feathered edges are what make the fog
    line trace the hillside instead of stair-stepping across DEM cells.

    A slab with no thickness -- the cloud base at or above the inversion -- has
    no fog anywhere, so it returns zeros rather than a thin band of half-values
    where the two feathered edges overlap.
    """
    grid = np.asarray(elevation, dtype=np.float64)
    if top_m <= base_m:
        return np.zeros_like(grid)
    # The base is feathered downwards only: ground at or above the cloud base is
    # fully inside the deck, and the softness below it represents the ragged
    # scud that hangs under a nominal ceiling. A symmetric band here would put
    # half the transition below sea level and leave coastal ground -- where the
    # fog is densest and the base is at the surface -- only partly fogged.
    entered = smoothstep(base_m - 2.0 * feather_m, base_m, grid)
    # The inversion is genuinely fuzzy in both directions, so the top is not.
    exited = 1.0 - smoothstep(top_m - feather_m, top_m + feather_m, grid)
    return entered * exited


def visibility_from_fog_fraction(
    fog_fraction: np.ndarray, max_visibility_m: float = 24000.0
) -> np.ndarray:
    """Map a 0-1 fog fraction onto a visibility in metres."""
    return np.clip(
        max_visibility_m * np.exp(-6.0 * np.asarray(fog_fraction, dtype=np.float64)),
        40.0,
        max_visibility_m,
    )


def classify_surface(
    elevation: np.ndarray,
    fog_fraction: np.ndarray,
    marine_influence: np.ndarray,
    base_m: float,
    top_m: float,
    feather_m: float = EDGE_FEATHER_M,
) -> np.ndarray:
    """Label each cell with what a person standing there would experience.

    - ``above_deck``  -- in sun, above the inversion, looking down at a white sea
    - ``in_fog``      -- inside the slab, visibility under a kilometre
    - ``under_deck``  -- below the cloud base: grey overhead, but you can see
    - ``clear``       -- no marine air here at all
    """
    grid = np.asarray(elevation, dtype=np.float64)
    states = np.full(grid.shape, "clear", dtype=object)
    has_marine = marine_influence > 0.3

    under = has_marine & (grid < base_m - feather_m)
    states[under] = "under_deck"

    above = has_marine & (grid >= top_m)
    states[above] = "above_deck"

    states[fog_fraction > 0.25] = "in_fog"
    return states
