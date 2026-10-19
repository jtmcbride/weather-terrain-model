import CoreGraphics
import Foundation
import Testing
import FogKit
@testable import FogRender

// Rendering is texture, not physics, so these pin the properties that keep it
// honest: the escape hatch shows the model unaltered, smoothing never invents
// fog, and pixels land where the map will draw them.

private func alphas(_ image: CGImage) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    return stride(from: 3, to: data.count, by: 4).map { data[$0] }
}

/// A field fogged north of `latitude` and clear south of it.
private func band(northOf latitude: Double, gridY: Int = 280, gridX: Int = 8) -> Grid<Double> {
    let geometry = RasterGeometry(bounds: .sanFrancisco, gridX: gridX, gridY: gridY)
    var grid = Grid(width: gridX, height: gridY, repeating: 0.0)
    for row in 0..<gridY where geometry.latitude(row: row) > latitude {
        for col in 0..<gridX { grid[row, col] = 1 }
    }
    return grid
}

@Test func withoutBillowAlphaIsAFunctionOfFogFractionAlone() {
    // The escape hatch: billow 0 adds nothing the model did not produce.
    let field = FogField(width: 5, height: 1, values: [0, 0.25, 0.5, 0.75, 1])
    let image = FogTexture.render(field, density: 0.8, billow: 0)
    let expected = field.values.map { UInt8(255 * pow(Double($0), 1.25) * 0.8) }
    #expect(alphas(image) == expected)
}

@Test func billowLeavesTheClearAirAndTheDenseCoreAlone() {
    // Edge weight 4f(1-f) vanishes at f = 0 and f = 1, so texture only ever
    // appears at the deck's margins.
    let values = [Float](repeating: 0, count: 64 * 64) + [Float](repeating: 1, count: 64 * 64)
    let field = FogField(width: 64, height: 128, values: values)
    let flat = alphas(FogTexture.render(field, density: 1, billow: 0))
    let billowed = alphas(FogTexture.render(field, density: 1, billow: 1))
    #expect(flat == billowed)
}

@Test func billowDoesTextureTheMargins() {
    let field = FogField(width: 64, height: 64, values: [Float](repeating: 0.5, count: 64 * 64))
    let billowed = Set(alphas(FogTexture.render(field, density: 1, billow: 1)))
    #expect(billowed.count > 10)
}

@Test func smoothingNeverOvershootsIntoAHalo() {
    // A hard fog edge: Catmull-Rom rings past it, and must be clamped.
    var grid = Grid(width: 20, height: 20, repeating: 0.0)
    for row in 0..<20 { for col in 10..<20 { grid[row, col] = 1 } }
    let field = FogTexture.prepare(grid, bounds: .sanFrancisco, detail: 4)
    #expect(field.values.allSatisfy { (0...1).contains($0) })
    // And clear air well away from the edge stays exactly clear.
    #expect(field.values[0] == 0)
}

@Test func detailSetsPixelsPerCellUpToTheMaximumEdge() {
    let grid = Grid(width: 256, height: 280, repeating: 0.0)
    #expect(FogTexture.prepare(grid, bounds: .sanFrancisco, detail: 3).width == 768)
    let big = Grid(width: 560, height: 612, repeating: 0.0)
    let field = FogTexture.prepare(big, bounds: .sanFrancisco, detail: 5)
    #expect(field.width == FogTexture.maxEdge && field.height == FogTexture.maxEdge)
}

@Test func rowsAreSampledWhereTheMapWillDrawThem() {
    // A fog edge at 37.70 N. The map stretches the image linearly in Mercator
    // y, so the edge pixel must sit at 37.70's Mercator position, not its
    // linear-in-latitude one -- which is ~49 m out mid-domain.
    let bounds = Bounds.sanFrancisco
    let field = FogTexture.prepare(band(northOf: 37.70), bounds: bounds, detail: 3)
    let column = (0..<field.height).map { field.values[$0 * field.width] }
    let edgePixel = Double(column.firstIndex { $0 < 0.5 }!)

    let north = FogTexture.mercatorY(bounds.latMax), south = FogTexture.mercatorY(bounds.latMin)
    let mercatorPixel = (FogTexture.mercatorY(37.70) - north) / (south - north) * Double(field.height - 1)
    let linearPixel = (bounds.latMax - 37.70) / (bounds.latMax - bounds.latMin) * Double(field.height - 1)

    let metresPerPixel = (bounds.latMax - bounds.latMin) * 111_320 / Double(field.height - 1)
    #expect(abs(edgePixel - mercatorPixel) <= 2, "edge at \(edgePixel), Mercator says \(mercatorPixel)")
    // The correction is real at this size: several pixels, tens of metres.
    #expect(abs(mercatorPixel - linearPixel) * metresPerPixel > 30)
}

@Test func mercatorRowsSpanTheGridExactly() {
    let rows = FogTexture.mercatorSourceRows(height: 840, gridY: 280, bounds: .sanFrancisco)
    #expect(abs(rows.first!) < 1e-9)
    #expect(abs(rows.last! - 279) < 1e-9)
    #expect(zip(rows, rows.dropFirst()).allSatisfy { $0 < $1 })
}

@Test func theNoiseIsDeterministicAndNormalised() {
    let texture = FogNoise.texture
    #expect(texture.count == FogNoise.size * FogNoise.size)
    #expect(texture.allSatisfy { (0...1).contains($0) })
    // Tileable: sampling wraps.
    #expect(FogNoise.at(3, 5) == FogNoise.at(3 + 512, 5 - 512))
    // Pinned against the web page's hash, evaluated in node: Math.imul
    // arithmetic is multiplication mod 2^32.
    #expect(abs(FogNoise.hash(1, 2, 3) - 0.9527685323) < 1e-9)
    #expect(abs(FogNoise.hash(511, 300, 5) - 0.0788328455) < 1e-9)
}

// MARK: - Volume

private let volumeBounds = Bounds.sanFrancisco

@Test func ridgesPokingThroughTheDeckGetNoColumn() {
    var elevation = Grid(width: 40, height: 40, repeating: 10.0)
    let fog = Grid(width: 40, height: 40, repeating: 1.0)
    for row in 0..<40 { elevation[row, 20] = 400 }  // a thin ridge above a 300 m top
    let blocks = FogVolume.blocks(fog: fog, elevation: elevation, bounds: volumeBounds, topM: 300, budget: 100, billow: 0)
    // Coarsened to 4x4 blocks; the column of blocks containing the ridge is gone.
    #expect(blocks.count == 100 - 10)
    // The ridge is in column 20, which starts the fifth column of blocks.
    let ridgeBlockWest = volumeBounds.lonMin + 20.0 / 39 * (volumeBounds.lonMax - volumeBounds.lonMin)
    #expect(!blocks.contains { abs($0.west - ridgeBlockWest) < 1e-12 })
}

@Test func aThinFogTongueSurvivesCoarsening() {
    var fog = Grid(width: 40, height: 40, repeating: 0.0)
    for row in 0..<40 { fog[row, 21] = 0.9 }  // one cell wide
    let elevation = Grid(width: 40, height: 40, repeating: 10.0)
    let blocks = FogVolume.blocks(fog: fog, elevation: elevation, bounds: volumeBounds, topM: 300, budget: 100, billow: 0)
    #expect(blocks.count == 10)
    #expect(blocks.allSatisfy { $0.fog == 0.9 })
}

@Test func thinFogMakesShortColumnsThatTaperIntoTheEdge() {
    let elevation = Grid(width: 10, height: 10, repeating: 0.0)
    let dense = FogVolume.blocks(fog: Grid(width: 10, height: 10, repeating: 1.0), elevation: elevation,
                                 bounds: volumeBounds, topM: 300, budget: 100, billow: 0)
    let thin = FogVolume.blocks(fog: Grid(width: 10, height: 10, repeating: 0.2), elevation: elevation,
                                bounds: volumeBounds, topM: 300, budget: 100, billow: 0)
    // Dense fog reaches the inversion; roofs are measured from the ground.
    #expect(dense.allSatisfy { abs($0.height - 300) < 1e-9 })
    #expect(thin.allSatisfy { abs($0.height - 300 * (0.42 + 0.58 * 0.2)) < 1e-9 })
}

@Test func billowedRoofsVaryGentlyBetweenNeighbours() {
    let fog = Grid(width: 120, height: 120, repeating: 1.0)
    let elevation = Grid(width: 120, height: 120, repeating: 0.0)
    let blocks = FogVolume.blocks(fog: fog, elevation: elevation, bounds: volumeBounds, topM: 300, budget: 14_400, billow: 1)
    let heights = blocks.map(\.height)
    #expect(heights.max()! > heights.min()!)
    // Low frequency: adjacent roofs differ by a small fraction of the deck.
    let jumps = zip(heights, heights.dropFirst()).map { abs($0 - $1) }
    #expect(jumps.sorted()[jumps.count * 9 / 10] < 300 * 0.05)
}
