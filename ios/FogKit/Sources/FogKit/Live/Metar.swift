import Foundation

// METAR surface observations from the NOAA Aviation Weather Center. Port of
// backend/app/providers/metar.py.
//
// The forecast lattice is model output at 2-11 km and can never show the fog
// edge the hills produce. METARs are real instruments reporting visibility and
// sky condition directly. KHAF (ocean side) against KSFO (bay side) is the pair
// that disagrees whenever the peninsula hills hold fog on the west.

public let metarURL = URL(string: "https://aviationweather.gov/api/data/metar")!
let statuteMileM = 1609.344
let footM = 0.3048
let knotMs = 0.514444

/// Bay Area reporting stations, `config.metar_station_ids`.
public let bayAreaMetarStations = [
    "KSFO", "KOAK", "KHAF", "KSQL", "KPAO", "KNUQ",
    "KHWD", "KCCR", "KAPC", "KDVO", "KSTS", "KLVK",
]

/// Octas implied by each sky-cover code, as a fraction.
let coverFraction: [String: Double] = [
    "SKC": 0, "CLR": 0, "NCD": 0, "NSC": 0, "CAVOK": 0,
    "FEW": 0.1875, "SCT": 0.4375, "BKN": 0.6875, "OVC": 1, "OVX": 1, "VV": 1,
]

/// Covers that constitute a ceiling: a deck rather than scattered cloud.
let ceilingCovers: Set<String> = ["BKN", "OVC", "OVX", "VV"]

/// Present weather meaning fog at the surface. Mist (BR) and haze are not fog.
let denseFogPresentWeather = try! NSRegularExpression(
    pattern: #"\b(?:[-+]?(?:MI|BC|PR|FZ)?FG)\b"#)

public struct MetarObservation: Sendable, Equatable, Codable {
    public var stationID: String
    public var latitude: Double
    public var longitude: Double
    public var elevationM: Double
    public var observedAt: String
    public var temperatureC: Double?
    public var dewPointC: Double?
    public var visibilityM: Double?
    public var windSpeedMs: Double?
    public var windDirectionDeg: Double?
    /// Metres above mean sea level, not above ground.
    public var ceilingM: Double?
    /// Metres above mean sea level, not above ground.
    public var lowestCloudBaseM: Double?
    public var lowCloudFraction: Double?
    public var reportsFog: Bool
    public var raw: String
    /// When this was fetched from the AWC; nil for an observation built in code.
    public var fetchedAt: Date?

    public init(
        stationID: String, latitude: Double, longitude: Double, elevationM: Double,
        observedAt: String = "", temperatureC: Double? = nil, dewPointC: Double? = nil,
        visibilityM: Double? = nil, windSpeedMs: Double? = nil, windDirectionDeg: Double? = nil,
        ceilingM: Double? = nil, lowestCloudBaseM: Double? = nil, lowCloudFraction: Double? = nil,
        reportsFog: Bool = false, raw: String = "", fetchedAt: Date? = nil
    ) {
        self.stationID = stationID
        self.latitude = latitude
        self.longitude = longitude
        self.elevationM = elevationM
        self.observedAt = observedAt
        self.temperatureC = temperatureC
        self.dewPointC = dewPointC
        self.visibilityM = visibilityM
        self.windSpeedMs = windSpeedMs
        self.windDirectionDeg = windDirectionDeg
        self.ceilingM = ceilingM
        self.lowestCloudBaseM = lowestCloudBaseM
        self.lowCloudFraction = lowCloudFraction
        self.reportsFog = reportsFog
        self.raw = raw
        self.fetchedAt = fetchedAt
    }

    public var dewPointDepressionC: Double? {
        guard let temperatureC, let dewPointC else { return nil }
        return temperatureC - dewPointC
    }
}

/// Parse the AWC `visib` field into statute miles. It is loosely typed
/// upstream: a number, `"10+"` for unrestricted, or `"1/2"` / `"1 1/2"`.
public func parseVisibilitySM(_ value: Any?) -> Double? {
    switch value {
    case nil, is NSNull: return nil
    case let number as NSNumber: return number.doubleValue
    default: break
    }
    var text = "\(value!)".trimmingCharacters(in: .whitespaces)
    while text.hasSuffix("+") { text.removeLast() }
    text = text.replacingOccurrences(of: "M", with: "").trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    var total = 0.0
    for part in text.split(separator: " ") {
        if let slash = part.firstIndex(of: "/") {
            guard let numerator = Double(part[..<slash]),
                  let denominator = Double(part[part.index(after: slash)...]),
                  denominator != 0 else { return nil }
            total += numerator / denominator
        } else {
            guard let whole = Double(part) else { return nil }
            total += whole
        }
    }
    return total
}

/// One AWC JSON record as an observation, or nil when it lacks the position or
/// elevation the terrain model needs, rather than guessing.
public func parseMetarRecord(_ record: [String: Any]) -> MetarObservation? {
    guard let latitude = jsonDouble(record["lat"]),
          let longitude = jsonDouble(record["lon"]),
          let elevation = jsonDouble(record["elev"]),
          let stationID = nonEmpty(record["icaoId"]) ?? nonEmpty(record["station_id"])
    else { return nil }

    var ceiling: Double?
    var lowestBase: Double?
    var lowCloud: Double?
    for case let layer as [String: Any] in record["clouds"] as? [Any] ?? [] {
        let cover = nonEmpty(layer["cover"])?.uppercased() ?? ""
        if let fraction = coverFraction[cover] { lowCloud = max(lowCloud ?? 0, fraction) }
        guard let baseFt = jsonDouble(layer["base"]) else { continue }
        let baseMSL = baseFt * footM + elevation
        if lowestBase == nil || baseMSL < lowestBase! { lowestBase = baseMSL }
        if ceilingCovers.contains(cover), ceiling == nil || baseMSL < ceiling! { ceiling = baseMSL }
    }

    let raw = nonEmpty(record["rawOb"]) ?? ""
    let rawRange = NSRange(raw.startIndex..., in: raw)
    return MetarObservation(
        stationID: stationID, latitude: latitude, longitude: longitude, elevationM: elevation,
        observedAt: nonEmpty(record["reportTime"]) ?? nonEmpty(record["obsTime"]) ?? "",
        temperatureC: jsonDouble(record["temp"]),
        dewPointC: jsonDouble(record["dewp"]),
        visibilityM: parseVisibilitySM(record["visib"]).map { $0 * statuteMileM },
        windSpeedMs: jsonDouble(record["wspd"]).map { $0 * knotMs },
        windDirectionDeg: jsonDouble(record["wdir"]),
        ceilingM: ceiling, lowestCloudBaseM: lowestBase, lowCloudFraction: lowCloud,
        reportsFog: denseFogPresentWeather.firstMatch(in: raw, range: rawRange) != nil,
        raw: raw)
}

/// A full AWC response, skipping records that cannot be used.
public func parseMetarPayload(_ payload: Any) -> [MetarObservation] {
    guard let records = payload as? [Any] else { return [] }
    return records.compactMap { ($0 as? [String: Any]).flatMap(parseMetarRecord) }
}

/// Python truthiness for a JSON string field: missing, null and "" are absent.
private func nonEmpty(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    let text = "\(value)"
    return text.isEmpty ? nil : text
}

/// Where surface observations come from. `MetarClient` in the app.
public protocol ObservationSource: Sendable {
    func observations(stationIDs: [String], maxAgeMinutes: Int, policy: FetchPolicy) async throws -> [MetarObservation]
}

private struct MetarKey: Hashable, Sendable, Codable {
    var stationIDs: [String]
    var maxAgeMinutes: Int
}

public final class MetarClient: ObservationSource {
    private let fetcher: HTTPFetching
    private let url: URL
    // METARs are hourly with SPECIs between. Re-asking every time the hour
    // slider moves buys nothing and risks being throttled out of the one
    // genuinely observed input the model has.
    private let cache: TtlCache<MetarKey, [MetarObservation]>
    private let now: @Sendable () -> Date

    /// With `disk`, observations persist across launches (see `DiskCache`).
    public init(
        fetcher: HTTPFetching = URLSessionFetcher(), url: URL = metarURL, cacheTTLSeconds: TimeInterval = 300,
        disk: DiskCache? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.url = url
        self.now = now
        cache = TtlCache(ttlSeconds: cacheTTLSeconds, maxEntries: 4, persistence: disk.map { .disk($0) })
    }

    public func cacheStats() async -> CacheStats { await cache.stats() }

    /// Seconds since this station set was last fetched, fresh or not.
    public func cachedAgeSeconds(stationIDs: [String], maxAgeMinutes: Int = 90) async -> TimeInterval? {
        await cache.ageSeconds(MetarKey(stationIDs: stationIDs, maxAgeMinutes: maxAgeMinutes))
    }

    public func observations(
        stationIDs: [String], maxAgeMinutes: Int = 90, policy: FetchPolicy = .normal
    ) async throws -> [MetarObservation] {
        guard !stationIDs.isEmpty else { return [] }
        let fetcher = self.fetcher, url = self.url, now = self.now
        let key = MetarKey(stationIDs: stationIDs, maxAgeMinutes: maxAgeMinutes)
        return try await cache.value(for: key, policy: policy) {
            try await Self.fetch(fetcher, url, stationIDs: stationIDs, maxAgeMinutes: maxAgeMinutes, fetchedAt: now())
        }
    }

    private static func fetch(
        _ fetcher: HTTPFetching, _ url: URL, stationIDs: [String], maxAgeMinutes: Int, fetchedAt: Date
    ) async throws -> [MetarObservation] {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let hours = max(1, Int((Double(maxAgeMinutes) / 60).rounded(.toNearestOrEven)))
        components.queryItems = [
            URLQueryItem(name: "ids", value: stationIDs.joined(separator: ",")),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "hours", value: String(hours)),
        ]
        let payload = try await fetcher.json(components.url!)

        // Every observation inside the window comes back; keep the most recent
        // per station, in first-seen station order.
        var order: [String] = []
        var latest: [String: MetarObservation] = [:]
        for var observation in parseMetarPayload(payload) {
            observation.fetchedAt = fetchedAt
            guard let existing = latest[observation.stationID] else {
                order.append(observation.stationID)
                latest[observation.stationID] = observation
                continue
            }
            if observation.observedAt >= existing.observedAt { latest[observation.stationID] = observation }
        }
        return order.map { latest[$0]! }
    }
}
