import Foundation
import Testing
@testable import FogKit

// Port of backend/tests/test_cache.py. The cache exists to keep the live
// upstreams *available*, not just fast: both rate limit anonymous callers and
// the app scrubs a 168-hour timeline.

@Test func aFreshEntryIsServedWithoutCallingTheFactory() async throws {
    let clock = FakeClock()
    let cache = TtlCache<String, Int>(ttlSeconds: 10, clock: clock.read)
    let calls = Locked(0)
    let factory: @Sendable () async throws -> Int = { calls.withLock { $0 += 1; return $0 } }

    #expect(try await cache.value(for: "k", factory: factory) == 1)
    #expect(try await cache.value(for: "k", factory: factory) == 1)
    clock.advance(11)
    #expect(try await cache.value(for: "k", factory: factory) == 2)
    #expect(calls.current == 2)
}

/// Single flight. Without it, the animation loop is the rate-limit burst.
@Test func concurrentMissesMakeOneUpstreamCall() async throws {
    let cache = TtlCache<String, Int>(ttlSeconds: 60)
    let calls = Locked(0)
    let (gate, open) = AsyncStream<Void>.makeStream()
    let factory: @Sendable () async throws -> Int = {
        calls.withLock { $0 += 1 }
        for await _ in gate { break }
        return calls.current
    }

    let results = try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<8 { group.addTask { try await cache.value(for: "k", factory: factory) } }
        // Let every caller arrive at the cache before the fetch completes.
        try await Task.sleep(for: .milliseconds(100))
        open.yield()
        open.finish()
        return try await group.reduce(into: []) { $0.append($1) }
    }
    #expect(calls.current == 1)
    #expect(results == Array(repeating: 1, count: 8))
}

/// A stale forecast beats an error; the pipeline can say so in `warnings`.
@Test func anExpiredEntryIsServedWhenTheRefreshFails() async throws {
    let clock = FakeClock()
    let cache = TtlCache<String, String>(ttlSeconds: 5, clock: clock.read)
    #expect(try await cache.value(for: "k") { "payload" } == "payload")
    clock.advance(60)
    #expect(try await cache.value(for: "k") { throw UpstreamDown() } == "payload")
    #expect(await cache.stats().staleServes == 1)
}

@Test func aFirstFetchFailureStillThrows() async {
    let cache = TtlCache<String, String>(ttlSeconds: 5)
    await #expect(throws: UpstreamDown.self) {
        try await cache.value(for: "k") { throw UpstreamDown() }
    }
}

@Test func theCacheEvictsTheOldestEntryPastItsCap() async throws {
    let cache = TtlCache<String, Int>(ttlSeconds: 60, maxEntries: 2)
    for key in ["a", "b", "c"] { _ = try await cache.value(for: key) { 1 } }
    #expect(await cache.peek("a") == nil)
    #expect(await cache.peek("b") == 1)
    #expect(await cache.peek("c") == 1)
}

// MARK: - Provider level: the property that actually removes the 429

func hourlyPayload(hours: Int = 48, extra: [String: Any] = [:]) -> [[String: Any]] {
    var hourly: [String: Any] = [
        "time": (0..<hours).map { String(format: "2026-09-05T%02d:00", $0 % 24) },
        "temperature_2m": (0..<hours).map { 15.0 + Double($0) * 0.01 },
        "precipitation": Array(repeating: 0.0, count: hours),
        "wind_speed_10m": Array(repeating: 10.0, count: hours),
        "wind_direction_10m": Array(repeating: 270.0, count: hours),
        "relative_humidity_2m": Array(repeating: 90.0, count: hours),
        "dew_point_2m": Array(repeating: 13.0, count: hours),
        "cloud_cover_low": Array(repeating: 80.0, count: hours),
    ]
    hourly.merge(extra) { $1 }
    return [["latitude": 37.7, "longitude": -122.4, "elevation": 12.0, "hourly": hourly]]
}

/// One Open-Meteo response covers the whole window, so scrubbing is free:
/// a timeline drag costs 1 upstream request rather than 168.
@Test func everyHourOfTheTimelineCostsOneForecastRequest() async throws {
    let fetcher = FakeFetcher { _ in (200, hourlyPayload()) }
    let client = OpenMeteoClient(fetcher: fetcher, cacheTTLSeconds: 900)

    var times: [String] = []
    for hour in 0..<24 {
        times.append(try await client.forecastPoints([(37.7, -122.4)], hourIndex: hour)[0].time)
    }
    #expect(fetcher.requestCount == 1)
    #expect(Set(times).count == 24)  // each hour really did resolve differently
}

@Test func aDifferentVariableSetIsADifferentCacheEntry() async throws {
    let fetcher = FakeFetcher { _ in (200, hourlyPayload()) }
    let client = OpenMeteoClient(fetcher: fetcher, cacheTTLSeconds: 900)
    _ = try await client.forecastPoints([(37.7, -122.4)], hourIndex: 0)
    _ = try await client.forecastPoints([(37.7, -122.4)], hourIndex: 0, includeOptional: true)
    #expect(fetcher.requestCount == 2)
}

@Test func metarObservationsAreCachedBetweenRequests() async throws {
    nonisolated(unsafe) let record: [String: Any] = [
        "icaoId": "KSFO", "lat": 37.62, "lon": -122.37, "elev": 3.0,
        "reportTime": "2026-09-05 15:56", "temp": 14.0, "dewp": 13.0, "visib": "1/2",
        "rawOb": "KSFO 051556Z 27008KT 1/2SM FG OVC002 14/13",
        "clouds": [["cover": "OVC", "base": 200]],
    ]
    let fetcher = FakeFetcher { _ in (200, [record]) }
    let client = MetarClient(fetcher: fetcher, cacheTTLSeconds: 300)

    let first = try await client.observations(stationIDs: ["KSFO"])
    let second = try await client.observations(stationIDs: ["KSFO"])
    #expect(fetcher.requestCount == 1)
    #expect(first == second)
    #expect(first[0].reportsFog)
    #expect(await client.cachedAgeSeconds(stationIDs: ["KSFO"]) != nil)
}
