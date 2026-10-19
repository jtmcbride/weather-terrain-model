import Foundation
import Testing
@testable import FogKit

// Port of backend/tests/test_cost_distance.py.

private let rows = 60, cols = 80
private let cellM = 100.0

// A row well south of the gap, so anything crossing here has to detour north.
private let southRow = 40
private let westCol = 12
private let justWestCol = 33
private let justEastCol = 47
private let ridgeCol = 40

private func flat(_ row: Int, _ col: Int) -> Int { row * cols + col }

private func distances(fogTopM: Double, beta: Double = 12) -> [Double] {
    CostSurface(
        elevation: peninsula(rows: rows, cols: cols), cellDyM: cellM, cellDxM: cellM,
        fogTopM: fogTopM, beta: beta, scaleM: 60, blockBufferM: 25
    ).distances(from: flat(southRow, westCol))
}

@Test func aRidgeAboveTheInversionBlocksTheCrossing() {
    let d = distances(fogTopM: 240)
    let west = d[flat(southRow, justWestCol)]
    let east = d[flat(southRow, justEastCol)]
    #expect(west.isFinite)
    // Reaching the east side means going north to the gap and back down.
    #expect(east > 3 * west)
}

@Test func theDetourIsTerrainNotGeometry() {
    // The two target cells are almost equidistant in a straight line...
    let geometry = RasterGeometry(bounds: peninsulaBounds, gridX: cols, gridY: rows)
    let straight = geographicDistances(
        geometry: geometry,
        latitude: geometry.latitude(row: southRow), longitude: geometry.longitude(col: westCol))
    #expect(straight[flat(southRow, justEastCol)] / straight[flat(southRow, justWestCol)] < 1.8)

    // ...but cost distance, which is the point, is not.
    let cost = distances(fogTopM: 240)
    #expect(cost[flat(southRow, justEastCol)] / cost[flat(southRow, justWestCol)] > 3)
}

@Test func terrainAboveTheInversionIsUnreachable() {
    // The crest is at 300 m, well past the 240 m top plus its 25 m buffer.
    #expect(!distances(fogTopM: 240)[flat(southRow, ridgeCol)].isFinite)
}

@Test func raisingTheFogTopOverTheCrestOpensTheRidge() {
    let blocked = distances(fogTopM: 240)
    let overtopping = distances(fogTopM: 400)
    let east = flat(southRow, justEastCol)
    #expect(overtopping[east] < 0.6 * blocked[east])
    // And the crest itself is now inside the layer.
    #expect(overtopping[flat(southRow, ridgeCol)].isFinite)
}

@Test func betaZeroStillBlocksButDoesNotPenaliseClimbing() {
    let penalised = distances(fogTopM: 240, beta: 12)
    let unpenalised = distances(fogTopM: 240, beta: 0)
    let east = flat(southRow, justEastCol)
    // Both must detour through the gap; the penalised one costs more.
    #expect(unpenalised[east].isFinite)
    #expect(penalised[east] >= unpenalised[east])
}

@Test func idwGivesUnreachableCellsNoInfluence() {
    var idw = InverseDistanceWeighting(cellCount: 3, power: 2)
    idw.add(distances: [10, .infinity, 40], value: 1)
    let (interpolated, reachable) = idw.result()
    #expect(abs(interpolated[0] - 1) < 1e-12)
    #expect(interpolated[1] == 0)
    #expect(reachable == [true, false, true])
}

@Test func idwBlendsTwoStationsByInverseSquare() {
    var idw = InverseDistanceWeighting(cellCount: 2, power: 2)
    idw.add(distances: [100, 100], value: 1)
    idw.add(distances: [100, 300], value: 0)
    let (interpolated, _) = idw.result()
    // Equidistant: straight average.
    #expect(abs(interpolated[0] - 0.5) < 1e-12)
    // Three times closer to the fogged station, so nine times the weight.
    #expect(abs(interpolated[1] - 0.9) < 1e-12)
}

@Test func cellIndexUsesNorthFirstRasterOrder() {
    let geometry = RasterGeometry(bounds: peninsulaBounds, gridX: 80, gridY: 60)
    let b = peninsulaBounds
    #expect(geometry.cellIndex(latitude: b.latMax, longitude: b.lonMin) == 0)
    #expect(geometry.cellIndex(latitude: b.latMin, longitude: b.lonMax) == 80 * 60 - 1)
}

@Test func cellIndexRejectsPointsOutsideTheDomain() {
    let geometry = RasterGeometry(bounds: peninsulaBounds, gridX: 80, gridY: 60)
    #expect(geometry.cellIndex(latitude: 38.5, longitude: -122.4) == nil)
    #expect(geometry.cellIndex(latitude: 37.7, longitude: -121.0) == nil)
}

@Test func parallelBatchesAreConsumedInOrder() {
    // IDW sums depend on station order, so batching must not reorder them.
    var seen: [Int] = []
    forEachInParallel(37) { $0 * 2 } consume: { index, value in
        #expect(value == index * 2)
        seen.append(index)
    }
    #expect(seen == Array(0..<37))
}

@Test func elevationGridsLoadNorthFirstFromRawFloat32() throws {
    let url = Bundle.module.url(forResource: "Fixtures/sf-160x176", withExtension: "f32")!
    let grid = try Grid<Double>.float32(contentsOf: url, width: 160, height: 176)
    // Mt Tamalpais is in the north-west, near the top of a north-first grid;
    // the south-east corner is bay flats.
    let geometry = RasterGeometry(bounds: .sanFrancisco, gridX: 160, gridY: 176)
    let tam = try #require(geometry.cellIndex(latitude: 37.9235, longitude: -122.5965))
    #expect(grid.values[tam] > 600)
    #expect(grid[175, 159] < 50)

    #expect(throws: ElevationGridError.self) {
        try Grid<Double>.float32(contentsOf: url, width: 160, height: 175)
    }
}
