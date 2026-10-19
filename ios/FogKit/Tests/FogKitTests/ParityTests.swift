import Foundation
import Testing
@testable import FogKit

// The port must compute what the backend computes. Fixtures are written by
// backend/scripts/export_parity_fixtures.py; regenerate them whenever the
// Python model changes. The physics tests are the specification -- these only
// check the port, including on the real SF DEM.

private struct Fixtures: Decodable {
    let grids: [GridCase]
    let slabs: [SlabCase]

    static let shared: Fixtures = {
        let url = Bundle.module.url(forResource: "Fixtures/parity", withExtension: "json")!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(Fixtures.self, from: Data(contentsOf: url))
    }()
}

private struct BoundsJSON: Decodable {
    let latMin, latMax, lonMin, lonMax: Double
    var bounds: Bounds { Bounds(latMin: latMin, latMax: latMax, lonMin: lonMin, lonMax: lonMax) }
}

private struct SlabJSON: Decodable {
    let baseM, topM: Double
    let inversionBaseM, inversionStrengthC, lclM, froudeNumber: Double?
    let blockingRegime: String
    let source: String
    let warnings: [String]

    var slab: SlabDiagnosis {
        SlabDiagnosis(
            baseM: baseM, topM: topM, inversionBaseM: inversionBaseM,
            inversionStrengthC: inversionStrengthC, lclM: lclM, froudeNumber: froudeNumber,
            blockingRegime: BlockingRegime(rawValue: blockingRegime)!, source: source, warnings: warnings)
    }
}

private struct StationJSON: Decodable {
    let source: String
    let stationId: String?
    let latitude, longitude, elevation, fogFraction: Double
    let cloudBaseM: Double?

    var station: FogStationInput {
        FogStationInput(
            source: source, latitude: latitude, longitude: longitude, elevation: elevation,
            fogFraction: fogFraction, stationID: stationId, cloudBaseM: cloudBaseM)
    }
}

private struct GridCase: Decodable, CustomTestStringConvertible {
    struct Expected: Decodable {
        let fogFraction, marineInfluence, surfaceState: String
        let usedStationIds: [String?]
        let warnings: [String]
    }

    let name: String
    let bounds: BoundsJSON
    let gridX, gridY: Int
    let elevation: String?
    let elevationFile: String?
    let stations: [StationJSON]
    let slab: SlabJSON
    let terrainRouting: Bool
    let edgeFeatherM: Double
    let expected: Expected

    var testDescription: String { name }

    var elevationGrid: Grid<Double> {
        let data: Data
        if let elevationFile {
            let url = Bundle.module.url(forResource: "Fixtures/" + elevationFile, withExtension: nil)!
            data = try! Data(contentsOf: url)
        } else {
            data = Data(base64Encoded: elevation!)!
        }
        return Grid(width: gridX, height: gridY, values: floats(data).map(Double.init))
    }
}

private struct LevelJSON: Decodable {
    let pressureHpa, temperatureC, heightM: Double
}

private struct SurfaceJSON: Decodable {
    let temperature2M, dewPoint2M, boundaryLayerHeight: Double?

    enum CodingKeys: String, CodingKey {
        // convertFromSnakeCase turns `temperature_2m` into `temperature2M`.
        case temperature2M, dewPoint2M, boundaryLayerHeight
    }
}

private struct SlabCase: Decodable, CustomTestStringConvertible {
    let name: String
    let levelsByPoint: [[LevelJSON]]
    let surfaceValues: [SurfaceJSON]
    let foggedStationElevations, observedCeilingsM, clearStationElevations: [Double]
    let defaultTopM: Double
    let meanWindMs: Double?
    let expected: SlabJSON
    let expectedOverride2625: SlabJSON

    var testDescription: String { name }
}

private func floats(_ data: Data) -> [Float] {
    data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

private func decodeFloats(_ base64: String) -> [Double] {
    floats(Data(base64Encoded: base64)!).map(Double.init)
}

private let stateCodes: [SurfaceState: UInt8] = [.clear: 0, .underDeck: 1, .aboveDeck: 2, .inFog: 3]

/// Expected grids are stored as float32, so agreement is to float32 precision.
private let gridTolerance = 1e-6

@Test(arguments: Fixtures.shared.grids)
private func fogGridMatchesTheBackend(_ fixture: GridCase) throws {
    var options = FogGridOptions()
    options.terrainRouting = fixture.terrainRouting
    options.edgeFeatherM = fixture.edgeFeatherM
    let result = try buildFogGrid(
        bounds: fixture.bounds.bounds, elevation: fixture.elevationGrid,
        stations: fixture.stations.map(\.station), slab: fixture.slab.slab, options: options)

    let expectedFog = decodeFloats(fixture.expected.fogFraction)
    let expectedInfluence = decodeFloats(fixture.expected.marineInfluence)
    let fogError = zip(result.fogFraction.values, expectedFog).map { abs($0 - $1) }.max()!
    let influenceError = zip(result.marineInfluence.values, expectedInfluence).map { abs($0 - $1) }.max()!
    #expect(fogError < gridTolerance, "fog_fraction max error \(fogError)")
    #expect(influenceError < gridTolerance, "marine_influence max error \(influenceError)")

    // States are thresholds on fog (0.25) and influence (0.3); a cell sitting
    // on a threshold to within float32 precision may legitimately flip.
    let expectedStates = [UInt8](Data(base64Encoded: fixture.expected.surfaceState)!)
    let mismatched = result.surfaceState.values.indices.filter { i in
        stateCodes[result.surfaceState.values[i]] != expectedStates[i]
            && abs(expectedFog[i] - 0.25) > gridTolerance
            && abs(expectedInfluence[i] - 0.3) > gridTolerance
    }
    #expect(mismatched.isEmpty, "\(mismatched.count) surface states differ")

    #expect(result.usedStations.map(\.stationID) == fixture.expected.usedStationIds)
    #expect(result.warnings == fixture.expected.warnings)
}

@Test(arguments: Fixtures.shared.slabs)
private func slabDiagnosisMatchesTheBackend(_ fixture: SlabCase) {
    let slab = diagnoseSlab(
        levelsByPoint: fixture.levelsByPoint.map { levels in
            levels.map { PressureLevel(pressureHPa: $0.pressureHpa, temperatureC: $0.temperatureC, heightM: $0.heightM) }
        },
        surfaceValues: fixture.surfaceValues.map {
            SurfaceValues(temperature2m: $0.temperature2M, dewPoint2m: $0.dewPoint2M, boundaryLayerHeight: $0.boundaryLayerHeight)
        },
        foggedStationElevations: fixture.foggedStationElevations,
        observedCeilingsM: fixture.observedCeilingsM,
        clearStationElevations: fixture.clearStationElevations,
        defaultTopM: fixture.defaultTopM,
        meanWindMs: fixture.meanWindMs)
    expectSame(slab, fixture.expected.slab)
    expectSame(overrideSlabTop(slab, topM: 262.5), fixture.expectedOverride2625.slab)
}

private func expectSame(_ actual: SlabDiagnosis, _ expected: SlabDiagnosis) {
    func close(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a - b) <= 1e-9 * max(1, abs(b))
        default: false
        }
    }
    #expect(close(actual.baseM, expected.baseM))
    #expect(close(actual.topM, expected.topM))
    #expect(close(actual.inversionBaseM, expected.inversionBaseM))
    #expect(close(actual.inversionStrengthC, expected.inversionStrengthC))
    #expect(close(actual.lclM, expected.lclM))
    #expect(close(actual.froudeNumber, expected.froudeNumber))
    #expect(actual.blockingRegime == expected.blockingRegime)
    #expect(actual.source == expected.source)
    #expect(actual.warnings == expected.warnings)
}
