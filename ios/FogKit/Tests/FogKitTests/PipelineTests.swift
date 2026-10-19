import Foundation
import Testing
@testable import FogKit

// Port of the fog-grid and sources halves of backend/tests/test_api.py. As
// there, both upstreams are stubbed at the seam the pipeline depends on.

private let gridX = 60, gridY = 40

private let marineLevels = [
    PressureLevel(pressureHPa: 1000, temperatureC: 13.0, heightM: 110),
    PressureLevel(pressureHPa: 950, temperatureC: 12.4, heightM: 300),
    PressureLevel(pressureHPa: 925, temperatureC: 18.5, heightM: 560),
    PressureLevel(pressureHPa: 900, temperatureC: 19.0, heightM: 800),
]

private func forecastPoint(_ latitude: Double, _ longitude: Double, dropVisibility: Bool = false) -> ForecastPoint {
    var values: [String: Double] = [
        "temperature_2m": 14, "precipitation": 0, "wind_speed_10m": 18, "wind_direction_10m": 270,
        "relative_humidity_2m": 95, "dew_point_2m": 13.5, "cloud_cover_low": 95, "visibility": 600,
    ]
    if dropVisibility { values["visibility"] = nil }
    return ForecastPoint(
        latitude: latitude, longitude: longitude, elevation: 20, time: "2026-08-30T15:00",
        values: values, levels: marineLevels, missing: dropVisibility ? ["visibility"] : [])
}

private struct StubForecasts: ForecastSource {
    var fail = false
    var dropVisibility = false
    /// Make the first lattice point a clear sample on 80 m of model terrain.
    var clearHillSample = false

    func forecastPoints(
        _ coordinates: [(latitude: Double, longitude: Double)], hourIndex: Int,
        includeOptional: Bool, includeLevels: Bool
    ) async throws -> [ForecastPoint] {
        if fail { throw UpstreamDown() }
        var points = coordinates.map { forecastPoint($0.latitude, $0.longitude, dropVisibility: dropVisibility) }
        if clearHillSample {
            points[0].elevation = 80
            points[0].values["visibility"] = 16000
            points[0].values["dew_point_2m"] = 6
            points[0].values["cloud_cover_low"] = 0
        }
        return points
    }
}

private struct StubMetars: ObservationSource {
    var fail = false
    /// Replace KSFO with a clear station on a 150 m hill.
    var clearHillStation = false

    func observations(stationIDs: [String], maxAgeMinutes: Int) async throws -> [MetarObservation] {
        if fail { throw UpstreamDown() }
        if clearHillStation {
            return [
                MetarObservation(
                    stationID: "KHAF", latitude: 37.5134, longitude: -122.5011, elevationM: 20,
                    visibilityM: 400, ceilingM: 60, lowCloudFraction: 1, reportsFog: true),
                MetarObservation(
                    stationID: "HILL", latitude: 37.75, longitude: -122.45, elevationM: 150,
                    temperatureC: 20, dewPointC: 8, visibilityM: 16000, lowCloudFraction: 0),
            ]
        }
        return [
            MetarObservation(
                stationID: "KHAF", latitude: 37.5134, longitude: -122.5011, elevationM: 20,
                observedAt: "2026-08-30 15:00", temperatureC: 13, dewPointC: 13, visibilityM: 400,
                ceilingM: 60, lowCloudFraction: 1, reportsFog: true),
            MetarObservation(
                stationID: "KSFO", latitude: 37.6197, longitude: -122.3647, elevationM: 3,
                observedAt: "2026-08-30 15:00", temperatureC: 20, dewPointC: 11, visibilityM: 16000,
                lowCloudFraction: 0, reportsFog: false),
        ]
    }
}

private func pipeline(forecasts: StubForecasts = StubForecasts(), metars: StubMetars = StubMetars()) -> FogPipeline {
    FogPipeline(forecasts: forecasts, observations: metars)
}

private func run(_ pipeline: FogPipeline = pipeline(), _ configure: (inout FogRequest) -> Void = { _ in }) async throws -> FogReport {
    var request = FogRequest()
    configure(&request)
    return try await pipeline.run(request, elevation: peninsula(rows: gridY, cols: gridX))
}

@Test func theFogGridIsACompleteField() async throws {
    let report = try await run()
    #expect(report.grid.fogFraction.count == gridX * gridY)
    #expect(report.grid.fogFraction.values.allSatisfy { (0...1).contains($0) })
    #expect(report.grid.elevation.values.max() == 300)
    #expect(report.time == "2026-08-30T15:00")
}

@Test func theSlabIsDiagnosedFromTheSounding() async throws {
    let slab = try await run().slab
    // The inversion in marineLevels sits at 300 m.
    #expect(slab.inversionBaseM == 300)
    #expect(slab.topM >= 300)
    #expect(slab.blockingRegime != .unknown)
    #expect(slab.froudeNumber != nil)
}

@Test func metarObservationsReachTheStationList() async throws {
    let metars = try await run().grid.usedStations.filter { $0.source == "metar" }
    let byID = Dictionary(uniqueKeysWithValues: metars.map { ($0.stationID!, $0) })
    // KHAF is fogged on the coast; KSFO is clear on the bay side.
    #expect(byID["KHAF"]!.isFogged)
    #expect(!byID["KSFO"]!.isFogged)
    #expect(byID["KHAF"]!.fogFraction > byID["KSFO"]!.fogFraction)
}

@Test func theFogTopCanBeOverridden() async throws {
    let report = try await run { $0.fogTopOverrideM = 150 }
    #expect(report.slab.topM == 150)
    #expect(report.slab.source.contains("overridden"))
    // Nothing above a 150 m lid can be in fog.
    let elevation = report.grid.elevation.values, fog = report.grid.fogFraction.values
    #expect(elevation.indices.filter { elevation[$0] > 200 }.allSatisfy { fog[$0] == 0 })
}

@Test func terrainRoutingCanBeDisabledForComparison() async throws {
    let routed = try await run { $0.terrainRouting = true }
    let straight = try await run { $0.terrainRouting = false }
    #expect(routed.method.contains("cost-distance"))
    #expect(straight.method.contains("no terrain routing"))
    #expect(routed.grid.fogFraction.values != straight.grid.fogFraction.values)
}

@Test func aMissingVisibilityVariableIsReportedNotFatal() async throws {
    let report = try await run(pipeline(forecasts: StubForecasts(dropVisibility: true)))
    #expect(report.warnings.contains { $0.contains("does not publish 'visibility'") })
}

@Test func aMetarOutageDegradesToModelSamples() async throws {
    let report = try await run(pipeline(metars: StubMetars(fail: true)))
    #expect(report.warnings.contains { $0.contains("METAR") })
    #expect(report.grid.usedStations.allSatisfy { $0.source == "open-meteo" })
}

@Test func anUpstreamForecastFailureThrowsWithTheCause() async {
    await #expect {
        try await run(pipeline(forecasts: StubForecasts(fail: true)))
    } throws: { error in
        "\(error)".contains("upstream down")
    }
}

/// A wider feather softens the fog line, so more cells sit part-fogged.
/// Only observations are hard bounds on the slab. Reproduces 2026-10-19
/// 05:00 UTC, when one clear Open-Meteo sample on a model hillside lowered a
/// 300 m inversion to its own elevation and emptied the fog field.
@Test func aClearForecastSampleCannotCapTheSlab() async throws {
    let slab = try await run(pipeline(forecasts: StubForecasts(clearHillSample: true))).slab
    #expect(slab.topM >= 300)
    #expect(!slab.source.contains("clear elevated station"))
}

/// The rule still stands for real instruments.
@Test func aClearElevatedMetarStillBoundsTheSlab() async throws {
    let slab = try await run(pipeline(metars: StubMetars(clearHillStation: true))).slab
    #expect(slab.topM == 150)
    #expect(slab.source.contains("clear elevated station"))
}

@Test func theEdgeFeatherIsARequestLevelKnob() async throws {
    func partialCells(_ feather: Double) async throws -> Int {
        try await run { $0.edgeFeatherM = feather }.grid.fogFraction.values.filter { 0.02 < $0 && $0 < 0.98 }.count
    }
    #expect(try await partialCells(80) > partialCells(5))
}

@Test func sourcesReportBothUpstreamsAsLive() async {
    let statuses = await pipeline().sourceStatus()
    #expect(statuses.map(\.name) == ["open-meteo", "metar"])
    #expect(statuses[0].ok && statuses[0].validTime == "2026-08-30T15:00")
    #expect(statuses[1].ok && statuses[1].stations == ["KHAF", "KSFO"])
}

/// A degraded source is data, not an error -- same contract as `warnings`.
@Test func sourcesReportADeadUpstreamWithoutFailing() async {
    let statuses = await pipeline(metars: StubMetars(fail: true)).sourceStatus()
    #expect(!statuses[1].ok)
    #expect(statuses[1].detail.contains("upstream down"))
    // The model can still run on forecast samples alone.
    #expect(statuses[0].ok)
}

@Test func sourcesNameTheVariablesTheUpstreamDropped() async {
    let statuses = await pipeline(forecasts: StubForecasts(dropVisibility: true)).sourceStatus()
    #expect(statuses[0].missingVariables == ["visibility"])
    #expect(statuses[0].detail.contains("visibility"))
}

@Test func theStationLatticeIsSouthFirstRowMajor() {
    let lattice = stationLattice(.sanFrancisco, columns: 5, rows: 5)
    #expect(lattice.count == 25)
    #expect(lattice[0].latitude == 37.44 && lattice[0].longitude == -122.65)
    #expect(lattice[4].longitude == -122.15)
    #expect(lattice[24].latitude == 37.95)
}

@Test func theCurrentHourIndexCountsFromMidnightUTC() {
    // 04:35 UTC is index 4 whatever the device's time zone is.
    let date = ISO8601DateFormatter().date(from: "2026-10-19T04:35:00Z")!
    #expect(currentHourIndex(now: date) == 4)
}

// MARK: - Live

/// Opt-in, against the real upstreams: `FOGKIT_LIVE=1 swift test --filter Live`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FOGKIT_LIVE"] != nil))
func liveFogGridForTheCurrentHour() async throws {
    let url = Bundle.module.url(forResource: "Fixtures/sf-160x176", withExtension: "f32")!
    let elevation = try Grid<Double>.float32(contentsOf: url, width: 160, height: 176)
    let pipeline = FogPipeline()

    for status in await pipeline.sourceStatus() {
        print("source \(status.name): ok=\(status.ok) valid=\(status.validTime ?? "-") \(status.detail)")
    }
    var request = FogRequest()
    request.hourIndex = currentHourIndex()
    let report = try await pipeline.run(request, elevation: elevation)
    let fogged = report.grid.fogFraction.values.filter { $0 > 0.5 }.count
    print("valid \(report.time); slab \(Int(report.slab.baseM))-\(Int(report.slab.topM)) m "
        + "(\(report.slab.blockingRegime.rawValue)); \(report.grid.usedStations.count) stations; "
        + "\(fogged) of \(report.grid.fogFraction.count) cells fogged")
    print("slab source: \(report.slab.source)")
    for warning in report.warnings { print("warning: \(warning)") }
    #expect(report.grid.fogFraction.count == 160 * 176)
}
