import Foundation

// Open-Meteo forecasts. Port of backend/app/providers/open_meteo.py (the
// forecast half; elevation comes from bundled grids, never the network).

let forecastURL = URL(string: "https://api.open-meteo.com/v1/forecast")!
let forecastBatchSize = 50
let forecastDays = 7
let kmhToMs = 1000.0 / 3600.0

/// Always requested. Every model Open-Meteo serves carries these.
let coreSurfaceVariables = [
    "temperature_2m", "precipitation", "wind_speed_10m", "wind_direction_10m",
    "relative_humidity_2m", "dew_point_2m", "cloud_cover_low",
]

/// Requested but not depended on: both are model-dependent. If the upstream
/// rejects them, the slab falls back to dewpoint depression and Espy's LCL.
let optionalSurfaceVariables = ["visibility", "boundary_layer_height"]

/// 1000-850 hPa spans ~100-1500 m, bracketing every Bay Area fog top.
let pressureLevels = [1000, 950, 925, 900, 850]

let pressureVariables = pressureLevels.flatMap { ["temperature_\($0)hPa", "geopotential_height_\($0)hPa"] }

/// One point's forecast at one hour.
public struct ForecastPoint: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var elevation: Double
    public var time: String
    public var values: [String: Double]
    /// Sorted by height.
    public var levels: [PressureLevel]
    /// Requested variables the upstream did not provide, by name.
    public var missing: [String]

    public init(
        latitude: Double, longitude: Double, elevation: Double, time: String,
        values: [String: Double], levels: [PressureLevel] = [], missing: [String] = []
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.time = time
        self.values = values
        self.levels = levels
        self.missing = missing
    }
}

/// Where forecast samples come from. `OpenMeteoClient` in the app.
public protocol ForecastSource: Sendable {
    func forecastPoints(
        _ coordinates: [(latitude: Double, longitude: Double)], hourIndex: Int,
        includeOptional: Bool, includeLevels: Bool
    ) async throws -> [ForecastPoint]
}

/// The whole hourly series for one point, as the upstream returned it.
struct HourlyLocation: Sendable {
    var latitude: Double
    var longitude: Double
    var elevation: Double
    var times: [String]
    var series: [String: [Double?]]
}

private struct CacheKey: Hashable, Sendable {
    var coordinates: [String]
    var variables: [String]
}

public final class OpenMeteoClient: ForecastSource {
    private let fetcher: HTTPFetching
    // Keyed by (coordinates, variables) and *not* by hour: one payload covers
    // the whole forecast window, so a timeline drag is one request, not 168.
    private let cache: TtlCache<CacheKey, [HourlyLocation]>

    public init(fetcher: HTTPFetching = URLSessionFetcher(), cacheTTLSeconds: TimeInterval = 900) {
        self.fetcher = fetcher
        cache = TtlCache(ttlSeconds: cacheTTLSeconds, maxEntries: 4)
    }

    public func cacheStats() async -> CacheStats { await cache.stats() }

    /// Hourly forecasts for many points in as few requests as possible:
    /// Open-Meteo takes comma-separated coordinates, so N points cost
    /// ceil(N / 50) requests. If the upstream rejects the optional variables
    /// (a 400), the request is retried once with the core set, and the dropped
    /// names are reported on each point's `missing`.
    public func forecastPoints(
        _ coordinates: [(latitude: Double, longitude: Double)], hourIndex: Int,
        includeOptional: Bool = false, includeLevels: Bool = false
    ) async throws -> [ForecastPoint] {
        guard !coordinates.isEmpty else { return [] }
        var variables = coreSurfaceVariables
        if includeOptional { variables += optionalSurfaceVariables }
        if includeLevels { variables += pressureVariables }

        let batches = stride(from: 0, to: coordinates.count, by: forecastBatchSize).map {
            Array(coordinates[$0..<min($0 + forecastBatchSize, coordinates.count)])
        }
        do {
            return try await fetchAll(batches, hourIndex: hourIndex, variables: variables, wantLevels: includeLevels)
        } catch let error as HTTPStatusError where error.statusCode == 400 && variables != coreSurfaceVariables {
            // A variable this model does not publish. Retry with what every
            // model carries.
            let dropped = variables.filter { !coreSurfaceVariables.contains($0) }
            let points = try await fetchAll(batches, hourIndex: hourIndex, variables: coreSurfaceVariables, wantLevels: false)
            return points.map { point in
                var point = point
                point.missing += dropped
                return point
            }
        }
    }

    private func fetchAll(
        _ batches: [[(latitude: Double, longitude: Double)]], hourIndex: Int,
        variables: [String], wantLevels: Bool
    ) async throws -> [ForecastPoint] {
        try await withThrowingTaskGroup(of: (Int, [HourlyLocation]).self) { group in
            for (index, batch) in batches.enumerated() {
                let coordinates = batch.map { [$0.latitude, $0.longitude] }
                group.addTask { (index, try await self.locations(coordinates, variables: variables)) }
            }
            var byBatch = [[HourlyLocation]](repeating: [], count: batches.count)
            for try await (index, locations) in group { byBatch[index] = locations }
            return try byBatch.joined().map {
                try Self.parse($0, hourIndex: hourIndex, requested: variables, wantLevels: wantLevels)
            }
        }
    }

    private func locations(_ coordinates: [[Double]], variables: [String]) async throws -> [HourlyLocation] {
        let key = CacheKey(
            coordinates: coordinates.map { "\(coordinateString($0[0])),\(coordinateString($0[1]))" },
            variables: variables)
        let fetcher = self.fetcher
        return try await cache.value(for: key) {
            try await Self.fetchLocations(fetcher, coordinates, variables: variables)
        }
    }

    /// The raw hourly series for one batch. Deliberately not parameterised by
    /// hour: every hour the app can scrub to is already in this payload.
    private static func fetchLocations(
        _ fetcher: HTTPFetching, _ coordinates: [[Double]], variables: [String]
    ) async throws -> [HourlyLocation] {
        var components = URLComponents(url: forecastURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: coordinates.map { coordinateString($0[0]) }.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: coordinates.map { coordinateString($0[1]) }.joined(separator: ",")),
            URLQueryItem(name: "hourly", value: variables.joined(separator: ",")),
            URLQueryItem(name: "forecast_days", value: String(forecastDays)),
            URLQueryItem(name: "timezone", value: "UTC"),
        ]
        let payload = try await fetcher.json(components.url!)
        // A bare object for one coordinate, a list for many.
        let records = (payload as? [[String: Any]]) ?? [(payload as? [String: Any]) ?? [:]]
        return records.map { record in
            let hourly = record["hourly"] as? [String: Any] ?? [:]
            var series: [String: [Double?]] = [:]
            for name in variables {
                if let values = hourly[name] as? [Any] { series[name] = values.map(jsonDouble) }
            }
            return HourlyLocation(
                latitude: jsonDouble(record["latitude"]) ?? 0,
                longitude: jsonDouble(record["longitude"]) ?? 0,
                elevation: jsonDouble(record["elevation"]) ?? 0,
                times: (hourly["time"] as? [Any])?.map { "\($0)" } ?? [],
                series: series)
        }
    }

    static func parse(
        _ location: HourlyLocation, hourIndex: Int, requested: [String], wantLevels: Bool
    ) throws -> ForecastPoint {
        guard !location.times.isEmpty else { throw ForecastParseError.noHourlySeries }
        let index = min(hourIndex, location.times.count - 1)
        func value(_ name: String) -> Double? {
            guard let series = location.series[name], index < series.count else { return nil }
            return series[index]
        }

        var values: [String: Double] = [:]
        var missing: [String] = []
        for name in requested {
            if let parsed = value(name) { values[name] = parsed } else { missing.append(name) }
        }

        var levels: [PressureLevel] = []
        if wantLevels {
            for level in pressureLevels {
                guard let temperature = value("temperature_\(level)hPa"),
                      let height = value("geopotential_height_\(level)hPa") else { continue }
                levels.append(PressureLevel(pressureHPa: Double(level), temperatureC: temperature, heightM: height))
            }
            levels.sort { $0.heightM < $1.heightM }
        }

        return ForecastPoint(
            latitude: location.latitude, longitude: location.longitude, elevation: location.elevation,
            time: location.times[index], values: values, levels: levels, missing: missing)
    }
}

public enum ForecastParseError: Error, Equatable {
    case noHourlySeries
}
