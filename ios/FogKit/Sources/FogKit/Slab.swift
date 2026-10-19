import Foundation

// Marine-layer fog diagnosis. Port of backend/app/features/fog.py, whose module
// docstring has the physical reasoning: SF fog is a stratus slab with a base B
// and a top H, and the fog boundary is the level set where H meets the DEM.

let gravity = 9.80665
let kelvin = 273.15
/// Espy's approximation: the LCL is ~125 m above ground per degree of
/// dewpoint depression.
let espyCoefficient = 125.0
/// Vertical softness of the slab edges used by the slab *diagnosis*. The
/// occupancy feather is a separate, tunable `FogConfig.edgeFeatherM`.
public let defaultEdgeFeatherM = 30.0

/// One sample of a sounding. Port of `open_meteo.LevelSample`.
public struct PressureLevel: Sendable, Equatable {
    public var pressureHPa: Double
    public var temperatureC: Double
    public var heightM: Double

    public init(pressureHPa: Double, temperatureC: Double, heightM: Double) {
        self.pressureHPa = pressureHPa
        self.temperatureC = temperatureC
        self.heightM = heightM
    }
}

/// The surface variables slab diagnosis reads from one forecast point.
public struct SurfaceValues: Sendable, Equatable {
    public var temperature2m: Double?
    public var dewPoint2m: Double?
    public var boundaryLayerHeight: Double?

    public init(temperature2m: Double? = nil, dewPoint2m: Double? = nil, boundaryLayerHeight: Double? = nil) {
        self.temperature2m = temperature2m
        self.dewPoint2m = dewPoint2m
        self.boundaryLayerHeight = boundaryLayerHeight
    }
}

public enum BlockingRegime: String, Sendable {
    case blocked, overtopping, unknown
}

public struct SlabDiagnosis: Sendable, Equatable {
    public var baseM: Double
    public var topM: Double
    public var inversionBaseM: Double?
    public var inversionStrengthC: Double?
    public var lclM: Double?
    public var froudeNumber: Double?
    public var blockingRegime: BlockingRegime
    public var source: String
    public var warnings: [String]

    public init(
        baseM: Double, topM: Double, inversionBaseM: Double? = nil,
        inversionStrengthC: Double? = nil, lclM: Double? = nil, froudeNumber: Double? = nil,
        blockingRegime: BlockingRegime = .unknown, source: String, warnings: [String] = []
    ) {
        self.baseM = baseM
        self.topM = topM
        self.inversionBaseM = inversionBaseM
        self.inversionStrengthC = inversionStrengthC
        self.lclM = lclM
        self.froudeNumber = froudeNumber
        self.blockingRegime = blockingRegime
        self.source = source
        self.warnings = warnings
    }
}

/// Hermite smoothstep, clamped outside the edges.
func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
    if edge1 == edge0 { return value >= edge1 ? 1 : 0 }
    let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

/// Cloud base above ground, by Espy's approximation.
public func lclHeightM(temperatureC: Double, dewPointC: Double) -> Double {
    max(0, espyCoefficient * (temperatureC - dewPointC))
}

/// Potential temperature, referenced to 1000 hPa.
public func potentialTemperatureK(temperatureC: Double, pressureHPa: Double) -> Double {
    (temperatureC + kelvin) * pow(1000.0 / pressureHPa, 0.286)
}

/// The lowest layer where temperature increases with height, as
/// `(lower, upper)`, or nil for a profile that only cools (well mixed, no lid).
private func lowestInversion(_ levels: [PressureLevel]) -> (PressureLevel, PressureLevel)? {
    // Python's sorted() is stable; so is this, so tied heights keep their order.
    let samples = levels.enumerated()
        .sorted { ($0.element.heightM, $0.offset) < ($1.element.heightM, $1.offset) }
        .map(\.element)
    for (lower, upper) in zip(samples, samples.dropFirst()) where upper.temperatureC > lower.temperatureC {
        return (lower, upper)
    }
    return nil
}

/// `(height_m, strength_c)` at the base of the lowest inversion.
public func inversionBase(_ levels: [PressureLevel]) -> (heightM: Double, strengthC: Double)? {
    lowestInversion(levels).map { ($0.heightM, $1.temperatureC - $0.temperatureC) }
}

/// Potential-temperature jump across the lowest inversion, in kelvin.
public func inversionThetaJump(_ levels: [PressureLevel]) -> Double? {
    lowestInversion(levels).map { lower, upper in
        potentialTemperatureK(temperatureC: upper.temperatureC, pressureHPa: upper.pressureHPa)
            - potentialTemperatureK(temperatureC: lower.temperatureC, pressureHPa: lower.pressureHPa)
    }
}

/// Shallow-water Froude number `U / sqrt(g' h)` for a capped marine layer.
/// Below 1 the layer is blocked by an obstacle; above 1 it over-tops it.
public func froudeNumber(
    windSpeedMs: Double, layerDepthM: Double, thetaJumpK: Double, meanThetaK: Double = 288.0
) -> Double? {
    guard layerDepthM > 0, thetaJumpK > 0, meanThetaK > 0 else { return nil }
    let reducedGravity = gravity * thetaJumpK / meanThetaK
    let denominator = (reducedGravity * layerDepthM).squareRoot()
    guard denominator > 0 else { return nil }
    return windSpeedMs / denominator
}

/// Collapse one station's report into a 0-1 surface-fog fraction. Visibility
/// is the definition of fog, so it wins; dewpoint depression and low cloud are
/// the fallback for sources that do not publish it.
public func observedFogFraction(
    visibilityM: Double?,
    dewPointDepressionC: Double?,
    lowCloudFraction: Double?,
    reportsFog: Bool = false,
    fogVisibilityM: Double = 1000,
    clearVisibilityM: Double = 10000,
    fogDewPointDepressionC: Double = 2.5
) -> Double {
    var fraction: Double
    if let visibilityM {
        let span = max(clearVisibilityM - fogVisibilityM, 1)
        fraction = (clearVisibilityM - visibilityM) / span
    } else {
        var depressionTerm = 0.0
        if let dewPointDepressionC {
            let span = max(fogDewPointDepressionC, 1e-6)
            depressionTerm = (span - dewPointDepressionC) / span
        }
        fraction = 0.6 * depressionTerm + 0.4 * (lowCloudFraction ?? 0)
    }
    fraction = min(max(fraction, 0), 1)
    if reportsFog { fraction = max(fraction, 0.85) }
    return fraction
}

/// numpy.median: the mean of the two middle values for an even count.
func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}

/// Estimate one fog slab base and top for the whole domain.
///
/// The top is horizontally uniform on purpose: a spatially smeared top would
/// blur exactly the ridgeline contrast this model exists to reproduce.
/// Station observations are hard bounds and override the model.
public func diagnoseSlab(
    levelsByPoint: [[PressureLevel]],
    surfaceValues: [SurfaceValues],
    foggedStationElevations: [Double],
    observedCeilingsM: [Double],
    clearStationElevations: [Double] = [],
    defaultTopM: Double = 300,
    meanWindMs: Double? = nil
) -> SlabDiagnosis {
    var warnings: [String] = []

    // --- top: the inversion base -------------------------------------
    var inversionHeights: [Double] = []
    var inversionStrengths: [Double] = []
    var thetaJumps: [Double] = []
    for levels in levelsByPoint where !levels.isEmpty {
        guard let found = inversionBase(levels) else { continue }
        inversionHeights.append(found.heightM)
        inversionStrengths.append(found.strengthC)
        if let jump = inversionThetaJump(levels) { thetaJumps.append(jump) }
    }

    var inversionHeight: Double?
    var inversionStrength: Double?
    var topM: Double
    var source: String
    if !inversionHeights.isEmpty {
        inversionHeight = median(inversionHeights)
        inversionStrength = median(inversionStrengths)
        topM = inversionHeight!
        source = "inversion base from pressure-level profile"
    } else {
        let boundaryLayer = surfaceValues.compactMap(\.boundaryLayerHeight)
        if !boundaryLayer.isEmpty {
            topM = median(boundaryLayer)
            source = "boundary layer height"
        } else {
            topM = defaultTopM
            source = "default marine layer depth"
            warnings.append(
                "No inversion found in the pressure-level profile and no "
                + "boundary layer height available; using the configured default "
                + "fog top. Check that the upstream model publishes "
                + "temperature_*hPa.")
        }
    }

    // --- base: cloud base -------------------------------------------
    let lclValues = surfaceValues.compactMap { values -> Double? in
        guard let t = values.temperature2m, let td = values.dewPoint2m else { return nil }
        return lclHeightM(temperatureC: t, dewPointC: td)
    }
    let lcl = lclValues.isEmpty ? nil : median(lclValues)

    var baseM: Double
    if !observedCeilingsM.isEmpty {
        baseM = median(observedCeilingsM)
        source += " + observed ceilings"
    } else if let lcl {
        baseM = lcl
        source += " + LCL"
    } else {
        baseM = 0
    }

    // --- constrain with observations ---------------------------------
    // A station reporting fog at elevation e proves the slab reaches down to e
    // and up past it.
    if let highestFogged = foggedStationElevations.max(),
       let lowestFogged = foggedStationElevations.min() {
        if baseM > lowestFogged {
            baseM = lowestFogged
            source += " (base lowered to a fogged station)"
        }
        if topM < highestFogged + defaultEdgeFeatherM {
            topM = highestFogged + defaultEdgeFeatherM
            source += " (top raised to a fogged station)"
        }
    }

    // A clear station below the top only bounds it if it is elevated.
    let elevatedClear = clearStationElevations.filter { $0 > baseM + defaultEdgeFeatherM }
    if let bound = elevatedClear.min(), topM > bound,
       foggedStationElevations.isEmpty || bound > foggedStationElevations.max()! {
        topM = bound
        source += " (top lowered to a clear elevated station)"
    }

    if baseM >= topM {
        // The air condenses above the lid: a dry, clear day. The honest answer
        // is an empty slab, not a slab relocated upwards.
        baseM = topM
        warnings.append(
            "The cloud base is at or above the inversion, so no marine layer "
            + "is present; the fog field is empty.")
    }

    // --- flow regime --------------------------------------------------
    var froude: Double?
    var regime = BlockingRegime.unknown
    if let meanWindMs, !thetaJumps.isEmpty {
        froude = froudeNumber(windSpeedMs: meanWindMs, layerDepthM: topM, thetaJumpK: median(thetaJumps))
        if let froude { regime = froude >= 1 ? .overtopping : .blocked }
    }

    return SlabDiagnosis(
        baseM: baseM, topM: topM, inversionBaseM: inversionHeight,
        inversionStrengthC: inversionStrength, lclM: lcl, froudeNumber: froude,
        blockingRegime: regime, source: source, warnings: warnings)
}

/// Re-diagnose the slab with the inversion asserted at `topM` -- the "what
/// does the city look like under a 250 m marine layer" control. On a dry day
/// the diagnosed base sits above the new top; it drops to the surface rather
/// than collapsing the slab, or the slider would visibly do nothing.
public func overrideSlabTop(_ slab: SlabDiagnosis, topM: Double) -> SlabDiagnosis {
    var baseM = min(slab.baseM, topM)
    var source = slab.source + " (fog top overridden to \(pythonRound(topM)) m by request"
    if baseM >= topM {
        baseM = 0
        source += "; the diagnosed cloud base does not fit under it, so the "
        source += "deck is assumed to reach the surface"
    }
    source += ")"
    var result = slab
    result.baseM = baseM
    result.topM = topM
    result.source = source
    // The "no marine layer" warning described the slab this call replaced.
    result.warnings = slab.warnings.filter { !$0.contains("no marine layer") }
    return result
}

/// Python's `f"{x:.0f}"`: round half to even, no decimal point.
private func pythonRound(_ value: Double) -> String {
    String(format: "%.0f", value)
}

/// How much of the surface at each cell sits inside the slab: 1 between the
/// deck base and the inversion, feathered to 0 outside. The feathered edges are
/// what make the fog line trace the hillside instead of stair-stepping.
public func slabOccupancy(elevation: Double, baseM: Double, topM: Double, featherM: Double) -> Double {
    // A slab with no thickness has no fog, not a band of half-values where the
    // two feathered edges overlap.
    guard topM > baseM else { return 0 }
    // The base is feathered downwards only: ground at or above the cloud base
    // is fully inside the deck, and the softness below it is the scud under a
    // nominal ceiling.
    let entered = smoothstep(baseM - 2 * featherM, baseM, elevation)
    // The inversion is genuinely fuzzy in both directions.
    let exited = 1 - smoothstep(topM - featherM, topM + featherM, elevation)
    return entered * exited
}

/// Map a 0-1 fog fraction onto a visibility in metres.
public func visibilityFromFogFraction(_ fogFraction: Double, maxVisibilityM: Double = 24000) -> Double {
    min(max(maxVisibilityM * exp(-6 * fogFraction), 40), maxVisibilityM)
}

/// What a person standing in the cell would experience.
public enum SurfaceState: String, Sendable {
    /// In sun above the inversion, looking down at a white sea.
    case aboveDeck = "above_deck"
    /// Inside the slab, visibility under a kilometre.
    case inFog = "in_fog"
    /// Below the cloud base: grey overhead, but you can see.
    case underDeck = "under_deck"
    /// No marine air here at all.
    case clear
}

public func classifySurface(
    elevation: Double, fogFraction: Double, marineInfluence: Double,
    baseM: Double, topM: Double, featherM: Double
) -> SurfaceState {
    if fogFraction > 0.25 { return .inFog }
    let hasMarine = marineInfluence > 0.3
    if hasMarine && elevation >= topM { return .aboveDeck }
    if hasMarine && elevation < baseM - featherM { return .underDeck }
    return .clear
}
