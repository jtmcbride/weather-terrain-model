import Testing
@testable import FogKit

// Port of backend/tests/test_fog_model.py: the tests that encode the actual
// requirement. When two sides of a high ridge disagree, the fog boundary must
// land on the ridge rather than in open ground between the stations, and the
// fog surface must follow the shape of the hill.

private let rows = 60, cols = 80
private let southRow = 40

// The ridge occupies columns 36-44 with its crest at 40. Column 35 is open
// ground just west of it; column 47 is just east.
private let westOfRidge = 35
private let eastOfRidge = 47
private let crest = 40
private let gapRow = 7

private let geometry = RasterGeometry(bounds: peninsulaBounds, gridX: cols, gridY: rows)

private func slab(baseM: Double = 0, topM: Double = 240) -> SlabDiagnosis {
    SlabDiagnosis(
        baseM: baseM, topM: topM, inversionBaseM: topM, inversionStrengthC: 6, lclM: 0,
        froudeNumber: 0.6, blockingRegime: .blocked, source: "test")
}

private func station(column: Int, fogFraction: Double, name: String) -> FogStationInput {
    FogStationInput(
        source: "test", latitude: geometry.latitude(row: southRow),
        longitude: geometry.longitude(col: column), elevation: 10, fogFraction: fogFraction,
        stationID: name, visibilityM: fogFraction > 0.5 ? 300 : 16000)
}

// A fogged station on the ocean side and a clear one on the bay side: the
// "different readings on two sides" case.
private let foggedWest = station(column: 12, fogFraction: 1, name: "WEST")
private let clearEast = station(column: 50, fogFraction: 0, name: "EAST")

private func build(
    _ stations: [FogStationInput], terrainRouting: Bool = true, topM: Double = 240, baseM: Double = 0
) throws -> FogGridResult {
    var options = FogGridOptions()
    options.terrainRouting = terrainRouting
    return try buildFogGrid(
        bounds: peninsulaBounds, elevation: peninsula(rows: rows, cols: cols),
        stations: stations, slab: slab(baseM: baseM, topM: topM), options: options)
}

/// First column where marine influence drops below one half.
private func boundaryColumn(_ influence: Grid<Double>, row: Int) -> Int {
    (0..<influence.width).first { influence[row, $0] < 0.5 } ?? 0
}

@Test func fogHoldsUpToTheRidgeAndStopsDead() throws {
    let result = try build([foggedWest, clearEast])
    #expect(result.fogFraction[southRow, westOfRidge] > 0.8)
    #expect(result.fogFraction[southRow, eastOfRidge] < 0.1)
}

/// The regression this whole model exists to fix: straight-line weighting has
/// no barriers, so the fog edge lands midway between the stations, kilometres
/// west of the hill. Cost distance pins it to the ridge.
@Test func terrainRoutingPutsTheBoundaryOnTheRidgeNotInOpenGround() throws {
    let routed = try build([foggedWest, clearEast], terrainRouting: true)
    let straight = try build([foggedWest, clearEast], terrainRouting: false)

    let routedEdge = boundaryColumn(routed.marineInfluence, row: southRow)
    let straightEdge = boundaryColumn(straight.marineInfluence, row: southRow)

    // The ridge starts at column 36; the routed edge sits inside it.
    #expect((36...44).contains(routedEdge))
    // The straight-line edge falls well west of the hill.
    #expect(straightEdge < 34)
    #expect(routedEdge - straightEdge >= 4)

    // Just west of the hill, routing keeps the fog dense while straight-line
    // weighting has already thinned it out.
    #expect(routed.marineInfluence[southRow, westOfRidge] > 0.9)
    #expect(straight.marineInfluence[southRow, westOfRidge] < 0.4)
}

@Test func fogPoursThroughTheGapRatherThanOverTheCrest() throws {
    let result = try build([foggedWest, clearEast])
    let throughGap = result.marineInfluence[gapRow, eastOfRidge]
    let behindRidge = result.marineInfluence[southRow, eastOfRidge]
    #expect(throughGap > 0.3)
    #expect(throughGap > 50 * behindRidge)
}

@Test func theRidgeCrestStandsAboveTheDeck() throws {
    let result = try build([foggedWest], topM: 240)
    #expect(result.elevation[southRow, crest] > 240)
    #expect(result.fogFraction[southRow, crest] == 0)
    #expect([.aboveDeck, .clear].contains(result.surfaceState[southRow, crest]))
}

/// Same terrain, one parameter: the level set is what moves.
@Test func raisingTheFogTopSwallowsTheCrest() throws {
    let shallow = try build([foggedWest], topM: 240)
    let deep = try build([foggedWest], topM: 500)
    #expect(shallow.fogFraction[southRow, crest] == 0)
    #expect(deep.fogFraction[southRow, crest] > 0.8)
    #expect(deep.surfaceState[southRow, crest] == .inFog)
}

/// On a cone, the fog boundary must be the H contour, not a circle.
@Test func theFogEdgeTracesAnElevationContour() throws {
    let size = 61
    let elevation = conicalHill(rows: size, cols: size, summitM: 400)
    let fogTop = 200.0
    let cone = RasterGeometry(bounds: peninsulaBounds, gridX: size, gridY: size)
    let corner = FogStationInput(
        source: "test", latitude: cone.latitude(row: size - 1), longitude: cone.longitude(col: 0),
        elevation: elevation[size - 1, 0], fogFraction: 1)

    let result = try buildFogGrid(
        bounds: peninsulaBounds, elevation: elevation, stations: [corner],
        slab: slab(baseM: 0, topM: fogTop))

    let cells = elevation.values.indices
    let wellAbove = cells.filter { elevation.values[$0] > fogTop + 60 }
    let reachableBelow = cells.filter {
        elevation.values[$0] < fogTop - 60 && result.marineInfluence.values[$0] > 0.3
    }

    // Nothing above the top is fogged, however close to the station it is;
    // everything reachable below it is, however far away.
    #expect(wellAbove.allSatisfy { result.fogFraction.values[$0] == 0 })
    #expect(!reachableBelow.isEmpty)
    #expect(reachableBelow.allSatisfy { result.fogFraction.values[$0] > 0.25 })

    // And the edge really is the contour: the highest fogged cell sits within
    // the feather of the fog top.
    let highestFogged = cells.filter { result.fogFraction.values[$0] > 0.5 }
        .map { elevation.values[$0] }.max()!
    #expect(abs(highestFogged - fogTop) < 40)
}

/// Good surface visibility under a stratus deck is not a fog-free report.
@Test func aStationUnderALiftedDeckStillMarksMarineAirPresent() {
    let underDeck = FogStationInput(
        source: "test", latitude: geometry.latitude(row: southRow), longitude: geometry.longitude(col: 12),
        elevation: 10, fogFraction: 0, visibilityM: 16000, cloudBaseM: 150)
    #expect(underDeck.marinePresence(slabTopM: 300) == 1)
    // With no deck below the inversion, it really is a clear report.
    #expect(underDeck.marinePresence(slabTopM: 100) == 0)
}

@Test func hillsidesReachingIntoALiftedDeckAreInCloud() throws {
    let result = try build([foggedWest], topM: 500, baseM: 150)
    // The flats are under the deck: grey overhead, but you can see.
    #expect(result.fogFraction[southRow, 12] == 0)
    #expect(result.surfaceState[southRow, 12] == .underDeck)
    // The ridge flank at 243 m rises into it.
    #expect(result.elevation[southRow, 38] > 150)
    #expect(result.fogFraction[southRow, 38] > 0.5)
    #expect(result.surfaceState[southRow, 38] == .inFog)
}

@Test func anEmptySlabProducesNoFogAnywhere() throws {
    let result = try build([foggedWest], topM: 300, baseM: 300)
    #expect(result.fogFraction.values.max() == 0)
}

@Test func visibilityTracksTheFogFraction() throws {
    let result = try build([foggedWest, clearEast])
    #expect(result.visibilityM[southRow, westOfRidge] < 1000)
    #expect(result.visibilityM[southRow, eastOfRidge] > 20000)
}

@Test func stationsOutsideTheDomainAreDroppedWithAWarning() throws {
    let farAway = FogStationInput(source: "test", latitude: 40, longitude: -120, elevation: 0, fogFraction: 1)
    let result = try build([foggedWest, farAway])
    #expect(result.usedStations.count == 1)
    #expect(result.warnings.contains { $0.contains("outside the domain") })
}

@Test func aStationJustOutsideIsClampedToTheEdge() throws {
    let justSouth = FogStationInput(
        source: "test", latitude: peninsulaBounds.latMin - 0.05, longitude: -122.5,
        elevation: 20, fogFraction: 1, stationID: "KHAF-ish")
    #expect(try build([justSouth]).usedStations.count == 1)
}

@Test func noStationsIsAnError() {
    #expect(throws: FogModelError.noStations) { try build([]) }
}

/// An empty field from "no marine air" is a different answer from an empty
/// field from "the ridge blocked it", and the slider looks broken without it.
@Test func aClearDaySaysWhyTheFieldIsEmpty() throws {
    let result = try buildFogGrid(
        bounds: peninsulaBounds, elevation: peninsula(rows: 40, cols: 40),
        stations: [FogStationInput(
            source: "metar", latitude: 37.62, longitude: -122.37, elevation: 3, fogFraction: 0,
            stationID: "KSFO")],
        slab: SlabDiagnosis(baseM: 0, topM: 260, lclM: 900, source: "fog top overridden by request"))
    #expect(result.fogFraction.values.max() == 0)
    #expect(result.warnings.contains { $0.contains("No observation reports marine air") })
}
