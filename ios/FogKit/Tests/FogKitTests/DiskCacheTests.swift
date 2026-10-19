import Foundation
import Testing
@testable import FogKit

// The disk cache exists for two moments: the app opening, when it should draw
// the last forecast immediately, and an upstream outage or 429 at launch, when
// the in-memory cache is empty and stale-on-error had nothing to serve.

/// A wall clock tests move by hand, for `DiskCache` and the clients.
private final class WallClock: Sendable {
    private let date: Locked<Date>
    init(_ date: Date) { self.date = Locked(date) }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 = $0.addingTimeInterval(seconds) } }
    var read: @Sendable () -> Date { { [date] in date.current } }
}

private let sf = [(latitude: 37.7, longitude: -122.4)]

private func client(_ fetcher: FakeFetcher, _ directory: URL, _ clock: WallClock) -> OpenMeteoClient {
    OpenMeteoClient(
        fetcher: fetcher, cacheTTLSeconds: 900,
        disk: DiskCache(directory: directory, now: clock.read), now: clock.read)
}

private func healthy() -> FakeFetcher { FakeFetcher { _ in (200, hourlyPayload()) } }
private func rateLimited() -> FakeFetcher {
    FakeFetcher { _ in (429, ["reason": "Minutely API request limit exceeded."]) }
}

@Test func aFreshPersistedForecastSurvivesARelaunchWithoutAFetch() async throws {
    let directory = temporaryCacheDirectory(), clock = WallClock(testNow)
    _ = try await client(healthy(), directory, clock).forecastPoints(sf, hourIndex: 3)

    // A new process: new client, empty memory, same directory.
    let relaunched = healthy()
    let points = try await client(relaunched, directory, clock).forecastPoints(sf, hourIndex: 3)
    #expect(relaunched.requestCount == 0)
    #expect(points[0].time == "2026-09-05T03:00")
}

/// The case that showed no fog at all: a cold launch during a 429.
@Test func aStalePersistedForecastIsServedWhenTheUpstreamRefuses() async throws {
    let directory = temporaryCacheDirectory(), clock = WallClock(testNow)
    _ = try await client(healthy(), directory, clock).forecastPoints(sf, hourIndex: 3)
    clock.advance(2 * 3600)

    let refused = rateLimited()
    let points = try await client(refused, directory, clock).forecastPoints(sf, hourIndex: 5)
    #expect(refused.requestCount == 1)  // it did try
    #expect(points[0].time == "2026-09-05T05:00")
    #expect(clock.read().timeIntervalSince(points[0].fetchedAt) == 2 * 3600)
}

@Test func aStalePersistedForecastIsReplacedWhenTheUpstreamIsUp() async throws {
    let directory = temporaryCacheDirectory(), clock = WallClock(testNow)
    _ = try await client(healthy(), directory, clock).forecastPoints(sf, hourIndex: 0)
    clock.advance(3600)

    let refreshed = healthy()
    _ = try await client(refreshed, directory, clock).forecastPoints(sf, hourIndex: 0)
    #expect(refreshed.requestCount == 1)

    // And the refresh was written back: the next launch needs no fetch.
    let next = healthy()
    _ = try await client(next, directory, clock).forecastPoints(sf, hourIndex: 0)
    #expect(next.requestCount == 0)
}

@Test func cacheOnlyDrawsTheLastForecastWithoutTheNetwork() async throws {
    let directory = temporaryCacheDirectory(), clock = WallClock(testNow)
    _ = try await client(healthy(), directory, clock).forecastPoints(sf, hourIndex: 0)
    clock.advance(6 * 3600)  // long expired

    let untouched = healthy()
    let points = try await client(untouched, directory, clock).forecastPoints(sf, hourIndex: 6, policy: .cacheOnly)
    #expect(untouched.requestCount == 0)
    #expect(points[0].time == "2026-09-05T06:00")
}

@Test func cacheOnlyWithNothingCachedIsAMissNotAFetch() async {
    let untouched = healthy()
    await #expect(throws: CacheMiss.self) {
        try await client(untouched, temporaryCacheDirectory(), WallClock(testNow))
            .forecastPoints(sf, hourIndex: 0, policy: .cacheOnly)
    }
    #expect(untouched.requestCount == 0)
}

/// A model that rejected the optional variables was last cached under the
/// core set; cache-only must find it there, as the live retry would.
@Test func cacheOnlyFindsAPayloadCachedAfterTheOptionalSetWasRejected() async throws {
    let directory = temporaryCacheDirectory(), clock = WallClock(testNow)
    let picky = FakeFetcher { url -> (status: Int, body: Any) in
        url.query("hourly")!.contains("visibility") ? (400, ["reason": "unknown"]) : (200, hourlyPayload())
    }
    _ = try await client(picky, directory, clock).forecastPoints(sf, hourIndex: 0, includeOptional: true)

    let points = try await client(healthy(), directory, clock)
        .forecastPoints(sf, hourIndex: 0, includeOptional: true, policy: .cacheOnly)
    #expect(points[0].missing.contains("visibility"))
}

/// Indexing yesterday's payload by position would show a forecast a whole
/// day away from the hour asked for, with nothing on screen to say so.
@Test func yesterdaysPayloadResolvesTodaysHourByValidTime() throws {
    let yesterday = windowStart.addingTimeInterval(-24 * 3600)
    let times = (0..<168).map { OpenMeteoClient.timeFormatter.string(from: yesterday.addingTimeInterval(Double($0) * 3600)) }
    let index = OpenMeteoClient.seriesIndex(for: 5, windowStart: windowStart, times: times)
    #expect(times[index] == "2026-09-05T05:00")
    // A fresh payload is plain positional indexing, as in the backend.
    let fresh = (0..<168).map { OpenMeteoClient.timeFormatter.string(from: windowStart.addingTimeInterval(Double($0) * 3600)) }
    #expect(OpenMeteoClient.seriesIndex(for: 5, windowStart: windowStart, times: fresh) == 5)
    // Past the end of an old window, the nearest hour rather than a crash.
    #expect(OpenMeteoClient.seriesIndex(for: 167, windowStart: windowStart, times: times) == 167)
}

@Test func metarObservationsSurviveARelaunch() async throws {
    let directory = temporaryCacheDirectory(), clock = WallClock(testNow)
    let record: [String: Any] = ["icaoId": "KHAF", "lat": 37.51, "lon": -122.5, "elev": 20, "visib": 0.25,
                                 "reportTime": "2026-09-05T03:00:00Z", "rawOb": "KHAF 050300Z 1/4SM FG"]
    nonisolated(unsafe) let payload = [record]
    let disk = DiskCache(directory: directory, now: clock.read)
    _ = try await MetarClient(fetcher: FakeFetcher { _ in (200, payload) }, disk: disk, now: clock.read)
        .observations(stationIDs: ["KHAF"])

    clock.advance(3600)
    let refused = FakeFetcher { _ in (503, ["error": "down"]) }
    let observations = try await MetarClient(fetcher: refused, disk: disk, now: clock.read)
        .observations(stationIDs: ["KHAF"])
    #expect(observations.map(\.stationID) == ["KHAF"])
    #expect(observations[0].reportsFog)
    #expect(observations[0].fetchedAt == testNow)
}

@Test func aCorruptCacheFileIsIgnored() async throws {
    let directory = temporaryCacheDirectory(), clock = WallClock(testNow)
    _ = try await client(healthy(), directory, clock).forecastPoints(sf, hourIndex: 0)
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        try Data("{not json".utf8).write(to: file)
    }
    let refetched = healthy()
    _ = try await client(refetched, directory, clock).forecastPoints(sf, hourIndex: 0)
    #expect(refetched.requestCount == 1)
}

@Test func aFileStampedInTheFutureIsNeverFresh() async throws {
    let directory = temporaryCacheDirectory(), clock = WallClock(testNow)
    _ = try await client(healthy(), directory, clock).forecastPoints(sf, hourIndex: 0)
    clock.advance(-3600)  // the device clock went backwards

    let refetched = healthy()
    _ = try await client(refetched, directory, clock).forecastPoints(sf, hourIndex: 0)
    #expect(refetched.requestCount == 1)
}

// MARK: - TtlCache semantics with persistence

@Test func aPersistedEntryIsAgedSoTheTTLStillApplies() async throws {
    let store = Locked<[String: (Int, TimeInterval)]>(["k": (7, 50)])  // stored 50 s ago
    let persistence = CachePersistence<String, Int>(
        load: { key in store.current[key].map { ($0.0, $0.1) } },
        save: { key, value in store.withLock { $0[key] = (value, 0) } })
    let clock = FakeClock()
    let cache = TtlCache<String, Int>(ttlSeconds: 60, clock: clock.read, persistence: persistence)

    #expect(try await cache.value(for: "k") { 99 } == 7)    // 50 s old: fresh
    #expect(await cache.ageSeconds("k") == 50)
    clock.advance(11)                                         // 61 s old: expired
    #expect(try await cache.value(for: "k") { 99 } == 99)
    #expect(store.current["k"]?.0 == 99)                      // and written back
}

// MARK: - The pipeline says when it is showing old data

private struct CachedForecasts: ForecastSource {
    let fetchedAt: Date
    func forecastPoints(
        _ coordinates: [(latitude: Double, longitude: Double)], hourIndex: Int,
        includeOptional: Bool, includeLevels: Bool, policy: FetchPolicy
    ) async throws -> [ForecastPoint] {
        coordinates.map {
            ForecastPoint(
                latitude: $0.latitude, longitude: $0.longitude, elevation: 10, time: "2026-09-05T05:00",
                values: ["temperature_2m": 14, "dew_point_2m": 13.8, "visibility": 400, "cloud_cover_low": 100],
                fetchedAt: fetchedAt)
        }
    }
}

private struct NoMetars: ObservationSource {
    func observations(stationIDs: [String], maxAgeMinutes: Int, policy: FetchPolicy) async throws -> [MetarObservation] { [] }
}

@Test func aStaleForecastIsNamedInTheWarnings() async throws {
    let pipeline = FogPipeline(
        forecasts: CachedForecasts(fetchedAt: testNow.addingTimeInterval(-(3 * 3600 + 5 * 60))),
        observations: NoMetars(), now: { testNow })
    let report = try await pipeline.run(FogRequest(), elevation: peninsula(rows: 20, cols: 20))
    #expect(report.warnings.contains { $0.hasPrefix("Showing a forecast fetched 3 h 05 min ago") })
}

@Test func aFreshForecastIsNotFlagged() async throws {
    let pipeline = FogPipeline(
        forecasts: CachedForecasts(fetchedAt: testNow.addingTimeInterval(-120)),
        observations: NoMetars(), now: { testNow })
    let report = try await pipeline.run(FogRequest(), elevation: peninsula(rows: 20, cols: 20))
    #expect(!report.warnings.contains { $0.contains("Showing a forecast fetched") })
}

@Test func agesReadNaturally() {
    #expect(FogPipeline.describeAge(40 * 60) == "40 min")
    #expect(FogPipeline.describeAge(3 * 3600 + 5 * 60) == "3 h 05 min")
    #expect(FogPipeline.describeAge(3 * 24 * 3600) == "3 days")
}
