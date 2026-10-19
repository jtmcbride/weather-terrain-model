import Foundation
import Testing
@testable import FogKit

// Opt-in timing at real grid sizes. Point FOGKIT_BENCH_DIR at a directory of
// raw float32 grids named bench-<x>x<y>.f32 (north-first), then:
//
//     FOGKIT_BENCH_DIR=/path swift test -c release --filter Benchmark

private let benchDir = ProcessInfo.processInfo.environment["FOGKIT_BENCH_DIR"]

@Test(.enabled(if: benchDir != nil), arguments: [(256, 280), (560, 612)])
func benchmarkFogGrid(gridX: Int, gridY: Int) throws {
    let url = URL(fileURLWithPath: benchDir!).appendingPathComponent("bench-\(gridX)x\(gridY).f32")
    let data = try Data(contentsOf: url)
    let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let elevation = Grid(width: gridX, height: gridY, values: floats.map(Double.init))

    // The same station set the backend sees: a 5x5 forecast lattice plus METARs.
    var stations: [FogStationInput] = []
    for i in 0..<5 {
        for j in 0..<5 {
            let lon = -122.65 + 0.125 * Double(j)
            stations.append(FogStationInput(
                source: "bench", latitude: 37.44 + 0.1275 * Double(i), longitude: lon,
                elevation: 0, fogFraction: lon < -122.5 ? 1 : 0))
        }
    }
    for i in 0..<8 {
        stations.append(FogStationInput(
            source: "bench", latitude: 37.62 + 0.01 * Double(i), longitude: -122.38 - 0.02 * Double(i),
            elevation: 0, fogFraction: 0))
    }
    let slab = SlabDiagnosis(baseM: 0, topM: 250, source: "bench")

    _ = try buildFogGrid(bounds: .sanFrancisco, elevation: elevation, stations: stations, slab: slab)
    let runs = 5
    let clock = ContinuousClock()
    let elapsed = try clock.measure {
        for _ in 0..<runs {
            _ = try buildFogGrid(bounds: .sanFrancisco, elevation: elevation, stations: stations, slab: slab)
        }
    }
    print("FogKit \(gridX)x\(gridY), \(stations.count) stations, "
        + "\(ProcessInfo.processInfo.activeProcessorCount) cores: \(elapsed / runs) per grid")
}
