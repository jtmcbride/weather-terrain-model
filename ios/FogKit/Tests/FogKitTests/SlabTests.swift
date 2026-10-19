import Testing
@testable import FogKit

// Port of backend/tests/test_fog.py.

/// A textbook summer Bay Area sounding: cool marine air to ~300 m, then a
/// sharp subsidence inversion, then warm dry air above.
let marineSounding = [
    PressureLevel(pressureHPa: 1000, temperatureC: 13.0, heightM: 110),
    PressureLevel(pressureHPa: 950, temperatureC: 12.4, heightM: 300),
    PressureLevel(pressureHPa: 925, temperatureC: 18.5, heightM: 560),
    PressureLevel(pressureHPa: 900, temperatureC: 19.0, heightM: 800),
    PressureLevel(pressureHPa: 850, temperatureC: 16.5, heightM: 1500),
]

/// A well-mixed profile that cools all the way up: no lid, no marine layer.
let mixedSounding = [
    PressureLevel(pressureHPa: 1000, temperatureC: 22.0, heightM: 110),
    PressureLevel(pressureHPa: 950, temperatureC: 19.0, heightM: 300),
    PressureLevel(pressureHPa: 925, temperatureC: 17.0, heightM: 560),
    PressureLevel(pressureHPa: 900, temperatureC: 15.0, heightM: 800),
]

private func approx(_ a: Double, _ b: Double, tolerance: Double = 1e-6) -> Bool {
    abs(a - b) <= tolerance * max(1, abs(b))
}

@Test func lclFollowsEspy() {
    #expect(lclHeightM(temperatureC: 15, dewPointC: 13) == 250)
    // Saturated air condenses at the surface.
    #expect(lclHeightM(temperatureC: 14, dewPointC: 14) == 0)
    // A negative depression is unphysical, not a negative cloud base.
    #expect(lclHeightM(temperatureC: 12, dewPointC: 14) == 0)
}

@Test func inversionBaseFindsTheLid() throws {
    let found = try #require(inversionBase(marineSounding))
    #expect(found.heightM == 300)
    #expect(approx(found.strengthC, 6.1))
}

@Test func inversionBaseIsNilWhenTheProfileOnlyCools() {
    #expect(inversionBase(mixedSounding) == nil)
    #expect(inversionThetaJump(mixedSounding) == nil)
}

@Test func inversionBaseIsOrderIndependent() {
    let reversed = inversionBase(marineSounding.reversed())
    let forward = inversionBase(marineSounding)
    #expect(reversed?.heightM == forward?.heightM)
    #expect(reversed?.strengthC == forward?.strengthC)
}

@Test func froudeNumberSeparatesBlockedFromOvertopping() throws {
    let jump = try #require(inversionThetaJump(marineSounding))
    #expect(jump > 0)

    let light = try #require(froudeNumber(windSpeedMs: 2, layerDepthM: 300, thetaJumpK: jump))
    let strong = try #require(froudeNumber(windSpeedMs: 20, layerDepthM: 300, thetaJumpK: jump))
    #expect(light < 1 && 1 < strong)

    // Degenerate inputs return nil rather than dividing by zero.
    #expect(froudeNumber(windSpeedMs: 5, layerDepthM: 0, thetaJumpK: jump) == nil)
    #expect(froudeNumber(windSpeedMs: 5, layerDepthM: 300, thetaJumpK: 0) == nil)
}

@Test func observedFogFractionPrefersMeasuredVisibility() {
    #expect(observedFogFraction(visibilityM: 400, dewPointDepressionC: nil, lowCloudFraction: nil) == 1)
    #expect(observedFogFraction(visibilityM: 16000, dewPointDepressionC: nil, lowCloudFraction: nil) == 0)
    let mid = observedFogFraction(visibilityM: 5000, dewPointDepressionC: nil, lowCloudFraction: nil)
    #expect(0 < mid && mid < 1)
}

@Test func observedFogFractionFallsBackWithoutVisibility() {
    let saturated = observedFogFraction(visibilityM: nil, dewPointDepressionC: 0, lowCloudFraction: 1)
    let dry = observedFogFraction(visibilityM: nil, dewPointDepressionC: 8, lowCloudFraction: 0)
    #expect(approx(saturated, 1))
    #expect(dry == 0)
}

@Test func presentWeatherRaisesAGenerousVisibilityReport() {
    // An observer reporting FG outranks a visibility that looks marginal.
    #expect(observedFogFraction(
        visibilityM: 9000, dewPointDepressionC: nil, lowCloudFraction: nil, reportsFog: true) == 0.85)
}

@Test func slabOccupancyIsALevelSetAgainstTerrain() {
    let occupancy = [0.0, 100, 239, 281, 400, 784].map {
        slabOccupancy(elevation: $0, baseM: 0, topM: 240, featherM: 30)
    }
    // Below the top: in the slab.
    #expect(approx(occupancy[1], 1))
    // Twin Peaks at 281 m pokes through a 240 m top, so it is out.
    #expect(occupancy[3] == 0)
    // Mount Tamalpais is far above it.
    #expect(occupancy[5] == 0)
    // The transition is monotonic, which is what makes the edge a contour.
    #expect(occupancy[2] > occupancy[3])
}

@Test func slabOccupancyExcludesGroundBelowALiftedDeck() {
    // Downtown, under the deck: grey overhead but not in cloud.
    #expect(slabOccupancy(elevation: 5, baseM: 150, topM: 400, featherM: 30) == 0)
    // A hillside that reaches into the deck is in cloud.
    #expect(approx(slabOccupancy(elevation: 200, baseM: 150, topM: 400, featherM: 30), 1))
}

@Test func visibilityMappingIsMonotonicAndBounded() {
    let visibility = [0.0, 0.25, 0.5, 0.75, 1].map { visibilityFromFogFraction($0, maxVisibilityM: 24000) }
    #expect(approx(visibility[0], 24000))
    #expect(visibility.last! < 100)
    #expect(zip(visibility, visibility.dropFirst()).allSatisfy { $1 < $0 })
}

@Test func diagnoseSlabUsesTheInversionWhenAvailable() {
    let slab = diagnoseSlab(
        levelsByPoint: [marineSounding, marineSounding],
        surfaceValues: [
            SurfaceValues(temperature2m: 14, dewPoint2m: 13),
            SurfaceValues(temperature2m: 14, dewPoint2m: 13),
        ],
        foggedStationElevations: [], observedCeilingsM: [], meanWindMs: 6)
    #expect(slab.topM == 300)
    #expect(slab.inversionBaseM == 300)
    #expect(approx(slab.lclM!, 125))
    #expect(approx(slab.baseM, 125))
    #expect(slab.blockingRegime != .unknown)
    #expect(slab.warnings.isEmpty)
}

@Test func diagnoseSlabWarnsAndDefaultsWithoutASounding() {
    let slab = diagnoseSlab(
        levelsByPoint: [[], []],
        surfaceValues: [SurfaceValues(temperature2m: 15, dewPoint2m: 14.5)],
        foggedStationElevations: [], observedCeilingsM: [], defaultTopM: 280)
    #expect(slab.topM == 280)
    #expect(!slab.warnings.isEmpty)
    #expect(slab.source.contains("default"))
}

@Test func boundaryLayerHeightIsUsedBeforeTheDefault() {
    let slab = diagnoseSlab(
        levelsByPoint: [[]],
        surfaceValues: [SurfaceValues(temperature2m: 15, dewPoint2m: 14, boundaryLayerHeight: 420)],
        foggedStationElevations: [], observedCeilingsM: [], defaultTopM: 280)
    #expect(slab.topM == 420)
    #expect(slab.source.contains("boundary layer"))
}

@Test func aFoggedStationForcesTheSlabToCoverIt() {
    // The model says the lid is at 300 m, but a station at 380 m reports fog.
    // The observation is a hard bound and must win.
    let slab = diagnoseSlab(
        levelsByPoint: [marineSounding],
        surfaceValues: [SurfaceValues(temperature2m: 14, dewPoint2m: 13)],
        foggedStationElevations: [380], observedCeilingsM: [])
    #expect(slab.topM > 380)
    #expect(slab.baseM <= 380)
}

@Test func observedCeilingSetsTheDeckBase() {
    let slab = diagnoseSlab(
        levelsByPoint: [marineSounding],
        surfaceValues: [SurfaceValues(temperature2m: 18, dewPoint2m: 12)],
        foggedStationElevations: [], observedCeilingsM: [180, 200, 220])
    #expect(slab.baseM == 200)
    #expect(slab.source.contains("observed ceilings"))
}

@Test func aCloudBaseAboveTheInversionMeansNoMarineLayer() {
    let slab = diagnoseSlab(
        levelsByPoint: [[]],
        surfaceValues: [SurfaceValues(temperature2m: 30, dewPoint2m: 0)],
        foggedStationElevations: [], observedCeilingsM: [], defaultTopM: 100)
    // The LCL here is 3750 m, far above the 100 m lid: dry, clear, no deck.
    #expect(slab.baseM == slab.topM)
    #expect(slab.warnings.contains { $0.contains("no marine layer") })
    // And an empty slab must yield no fog rather than a band of half-values.
    let ground = (0..<50).map { Double($0) * 4000 / 49 }
    #expect(ground.allSatisfy {
        slabOccupancy(elevation: $0, baseM: slab.baseM, topM: slab.topM, featherM: defaultEdgeFeatherM) == 0
    })
}

// MARK: - The fog-top override

/// A real, common state: the air condenses above the lid, so no deck.
private let dryDaySlab = SlabDiagnosis(
    baseM: 545, topM: 545, lclM: 912, source: "boundary layer height + LCL",
    warnings: ["... no marine layer is present; the fog field is empty."])

@Test func overridingTheTopOnADryDayStillProducesASlab() {
    // A scenario control that collapses to an empty slab leaves the slider
    // doing nothing on exactly the days you reach for it.
    let slab = overrideSlabTop(dryDaySlab, topM: 250)
    #expect(slab.topM == 250)
    #expect(slab.baseM < slab.topM)
    #expect(slab.source.contains("assumed to reach the surface"))
    #expect(!slab.warnings.contains { $0.contains("no marine layer") })
}

@Test func overridingTheTopKeepsADiagnosedBaseThatFitsUnderIt() {
    let slab = SlabDiagnosis(
        baseM: 60, topM: 300, inversionBaseM: 300, inversionStrengthC: 4, lclM: 80,
        froudeNumber: 0.6, blockingRegime: .blocked, source: "inversion base")
    let raised = overrideSlabTop(slab, topM: 450)
    #expect(raised.baseM == 60)
    #expect(raised.topM == 450)
    #expect(raised.blockingRegime == .blocked)
}

@Test func anOverriddenSlabActuallyFogsTheGroundBelowIt() {
    let slab = overrideSlabTop(dryDaySlab, topM: 300)
    let occupancy = [0.0, 120, 240, 400].map {
        slabOccupancy(elevation: $0, baseM: slab.baseM, topM: slab.topM, featherM: defaultEdgeFeatherM)
    }
    #expect(occupancy[0] > 0.9)  // sea level, deep inside the deck
    #expect(occupancy[1] > 0.9)
    #expect(occupancy[3] == 0)   // well above the asserted inversion
}
