import Foundation
import Testing
@testable import FogKit

// Port of backend/tests/test_metar.py, plus the Open-Meteo request and
// degradation behaviour the backend covers through test_api.py.

@Test func parseVisibilityHandlesTheLooseUpstreamTyping() {
    #expect(parseVisibilitySM(10) == 10)
    #expect(parseVisibilitySM(2.5) == 2.5)
    #expect(parseVisibilitySM("10+") == 10)
    #expect(parseVisibilitySM("1/2") == 0.5)
    #expect(parseVisibilitySM("1 1/2") == 1.5)
    #expect(parseVisibilitySM(nil) == nil)
    #expect(parseVisibilitySM("") == nil)
    #expect(parseVisibilitySM("garbage") == nil)
}

@Test func parseRecordConvertsUnitsAndFindsTheCeiling() throws {
    let observation = try #require(parseMetarRecord([
        "icaoId": "KSFO", "lat": 37.6197, "lon": -122.3647, "elev": 3,
        "reportTime": "2026-08-30 14:56:00", "temp": 15.0, "dewp": 14.0,
        "wspd": 10, "wdir": 270, "visib": "1/2",
        "clouds": [["cover": "FEW", "base": 400], ["cover": "OVC", "base": 900]],
        "rawOb": "KSFO 301456Z 27010KT 1/2SM FG OVC009 15/14 A2992",
    ]))
    #expect(observation.stationID == "KSFO")
    // Half a statute mile.
    #expect(observation.visibilityM == 0.5 * 1609.344)
    // 10 knots in metres per second.
    #expect(abs(observation.windSpeedMs! - 5.14444) < 1e-4)
    // The ceiling is the lowest broken-or-worse layer, feet AGL -> metres MSL.
    #expect(abs(observation.ceilingM! - (900 * 0.3048 + 3)) < 1e-6)
    // The FEW layer is lower but is not a ceiling.
    #expect(abs(observation.lowestCloudBaseM! - (400 * 0.3048 + 3)) < 1e-6)
    #expect(observation.lowCloudFraction == 1)
    #expect(observation.reportsFog)
    #expect(observation.dewPointDepressionC == 1)
}

@Test func scatteredCloudIsNotACeiling() throws {
    let observation = try #require(parseMetarRecord([
        "icaoId": "KOAK", "lat": 37.72, "lon": -122.22, "elev": 2, "visib": 10,
        "clouds": [["cover": "SCT", "base": 2500]],
        "rawOb": "KOAK 301453Z 28008KT 10SM SCT025 21/12 A2990",
    ]))
    #expect(observation.ceilingM == nil)
    #expect(observation.lowestCloudBaseM != nil)
    #expect(!observation.reportsFog)
}

@Test func mistIsNotReportedAsFog() throws {
    let observation = try #require(parseMetarRecord([
        "icaoId": "KHAF", "lat": 37.5134, "lon": -122.5011, "elev": 20, "visib": 4,
        "clouds": [Any](), "rawOb": "KHAF 301453Z 30006KT 4SM BR CLR 14/13 A2991",
    ]))
    #expect(!observation.reportsFog)
}

@Test func recordsWithoutPositionAreSkipped() {
    #expect(parseMetarRecord(["icaoId": "KXXX", "visib": 10]) == nil)
    let payload: [Any] = [
        ["icaoId": "KXXX", "visib": 10],
        ["icaoId": "KSFO", "lat": 37.6, "lon": -122.4, "elev": 3, "visib": 10],
        "not a record",
    ]
    #expect(parseMetarPayload(payload).map(\.stationID) == ["KSFO"])
}

@Test func parsePayloadRejectsNonLists() {
    #expect(parseMetarPayload(["error": "nope"]).isEmpty)
}

@Test func theLatestObservationPerStationWins() async throws {
    @Sendable func record(_ id: String, _ time: String, _ visib: Double) -> [String: Any] {
        ["icaoId": id, "lat": 37.6, "lon": -122.4, "elev": 3, "reportTime": time, "visib": visib]
    }
    let fetcher = FakeFetcher { _ in
        (200, [record("KSFO", "2026-09-05 14:56", 10), record("KHAF", "2026-09-05 15:10", 0.25),
               record("KSFO", "2026-09-05 15:56", 0.5)])
    }
    let observations = try await MetarClient(fetcher: fetcher).observations(stationIDs: ["KSFO", "KHAF"])
    #expect(observations.map(\.stationID) == ["KSFO", "KHAF"])
    #expect(observations[0].observedAt == "2026-09-05 15:56")
    // 90 minutes of history rounds to 2 hours, as Python's round() does.
    #expect(fetcher.requests.current[0].query("hours") == "2")
}

@Test func forecastRequestsBatchFiftyCoordinatesAndKeepTheirOrder() async throws {
    let fetcher = FakeFetcher { url in
        let latitudes: [Double] = url.query("latitude")!.split(separator: ",").map { Double($0)! }
        var locations: [[String: Any]] = []
        for latitude in latitudes {
            var location = hourlyPayload(hours: 3)[0]
            location["latitude"] = latitude
            locations.append(location)
        }
        return (200, locations)
    }
    let client = OpenMeteoClient(fetcher: fetcher, now: { testNow })
    let coordinates = (0..<120).map { (latitude: 37.0 + Double($0) * 0.001, longitude: -122.4) }
    let points = try await client.forecastPoints(coordinates, hourIndex: 0)

    #expect(fetcher.requestCount == 3)
    let expected: [Double] = coordinates.map { ($0.latitude * 1e5).rounded() / 1e5 }
    #expect(points.map(\.latitude) == expected)
    // Batches are fetched concurrently, so they can arrive in any order.
    let requests = fetcher.requests.current
    #expect(requests.contains { $0.query("latitude")!.hasPrefix("37.00000,37.00100,") })
    #expect(requests.allSatisfy { $0.query("forecast_days") == "7" })
}

/// `visibility` and `boundary_layer_height` are model-dependent. A 400 is a
/// model that does not publish one: retry with the core set and say so.
@Test func aRejectedOptionalVariableIsRetriedAndReportedMissing() async throws {
    let fetcher = FakeFetcher { url -> (status: Int, body: Any) in
        if url.query("hourly")!.contains("visibility") { return (400, ["reason": "unknown variable"]) }
        return (200, hourlyPayload())
    }
    let client = OpenMeteoClient(fetcher: fetcher, now: { testNow })
    let points = try await client.forecastPoints([(37.7, -122.4)], hourIndex: 0, includeOptional: true, includeLevels: true)

    #expect(fetcher.requestCount == 2)
    #expect(points[0].missing.contains("visibility"))
    #expect(points[0].missing.contains("temperature_950hPa"))
    #expect(points[0].levels.isEmpty)
}

@Test func otherHTTPErrorsAreNotRetried() async {
    let fetcher = FakeFetcher { _ in (429, ["reason": "Too many requests"]) }
    await #expect(throws: HTTPStatusError.self) {
        try await OpenMeteoClient(fetcher: fetcher, now: { testNow }).forecastPoints([(37.7, -122.4)], hourIndex: 0, includeOptional: true)
    }
    #expect(fetcher.requestCount == 1)
}

@Test func nullsInASeriesAreMissingNotZero() async throws {
    nonisolated(unsafe) let payload = hourlyPayload(hours: 3, extra: [
        "visibility": [NSNull(), 400.0, NSNull()],
        "temperature_950hPa": [12.4, 12.4, 12.4], "geopotential_height_950hPa": [300.0, 300.0, 300.0],
        "temperature_1000hPa": [13.0, 13.0, 13.0], "geopotential_height_1000hPa": [110.0, 110.0, 110.0],
    ])
    let client = OpenMeteoClient(fetcher: FakeFetcher { _ in (200, payload) }, now: { testNow })
    let first = try await client.forecastPoints([(37.7, -122.4)], hourIndex: 0, includeOptional: true, includeLevels: true)[0]
    let second = try await client.forecastPoints([(37.7, -122.4)], hourIndex: 1, includeOptional: true, includeLevels: true)[0]

    #expect(first.values["visibility"] == nil && first.missing.contains("visibility"))
    #expect(second.values["visibility"] == 400)
    // Levels are sorted by height and skip levels with no data.
    #expect(first.levels.map(\.heightM) == [110, 300])
}
