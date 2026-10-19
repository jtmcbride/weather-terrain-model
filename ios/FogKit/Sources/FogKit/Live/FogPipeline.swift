import Foundation

// Fetch -> diagnose -> route -> cut. Port of `main.fog_grid` and
// `main.sources`, minus HTTP: the API's response body becomes `FogReport`, its
// 502 becomes a thrown `FogPipelineError`, and its `warnings` array survives
// unchanged, because degradation is a feature here too, not an error path.

/// Per-render controls. Port of `schemas.FogGridRequest`; the grid size comes
/// from the elevation grid passed in.
public struct FogRequest: Sendable, Equatable {
    public var hourIndex = 0
    public var terrainRouting = true
    public var costBeta: Double
    public var idwPower: Double
    public var fogTopOverrideM: Double?
    public var useObservations = true
    public var edgeFeatherM: Double?

    public init(config: FogConfig = FogConfig()) {
        costBeta = config.costBeta
        idwPower = config.idwPower
    }
}

public struct FogReport: Sendable {
    /// The forecast's valid time, as Open-Meteo reports it (UTC).
    public var time: String
    public var bounds: Bounds
    public var grid: FogGridResult
    public var slab: SlabDiagnosis
    public var method: String
    public var warnings: [String]
    /// Seconds spent fetching (often zero: both upstreams are cached).
    public var fetchSeconds: Double
    /// Seconds spent in the model itself: routing, IDW and the vertical cut.
    public var modelSeconds: Double
}

public enum FogPipelineError: Error, CustomStringConvertible {
    case forecastUnavailable(String)

    public var description: String {
        switch self {
        case let .forecastUnavailable(detail): "Upstream forecast request failed: \(detail)"
        }
    }
}

public struct SourceStatus: Sendable, Equatable {
    public var name: String
    public var ok: Bool
    public var latencyMs: Double?
    /// The upstream's own timestamp: the model is only as current as this.
    public var validTime: String?
    public var sampleCount = 0
    public var missingVariables: [String] = []
    public var stations: [String] = []
    public var detail = ""
}

public final class FogPipeline: Sendable {
    public let forecasts: ForecastSource
    public let observations: ObservationSource
    public let config: FogConfig
    public let metarStationIDs: [String]
    public let metarMaxAgeMinutes: Int
    public let useMetarObservations: Bool
    private let now: @Sendable () -> Date

    /// The default sources talk to the live upstreams and persist to
    /// `Library/Caches/FogKit`, so the app can open on its last forecast.
    public init(
        forecasts: ForecastSource? = nil,
        observations: ObservationSource? = nil,
        config: FogConfig = FogConfig(),
        metarStationIDs: [String] = bayAreaMetarStations,
        metarMaxAgeMinutes: Int = 90,
        useMetarObservations: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.forecasts = forecasts ?? OpenMeteoClient(
            cacheTTLSeconds: config.forecastCacheTTLSeconds, disk: .caches("open-meteo"))
        self.observations = observations ?? MetarClient(
            cacheTTLSeconds: config.metarCacheTTLSeconds, disk: .caches("metar"))
        self.now = now
        self.config = config
        self.metarStationIDs = metarStationIDs
        self.metarMaxAgeMinutes = metarMaxAgeMinutes
        self.useMetarObservations = useMetarObservations
    }

    /// Diagnose the marine layer and render it against `elevation`, which
    /// must cover `config.bounds` north-first. `.cacheOnly` never touches the
    /// network: it draws whatever was last fetched, for the instant the app
    /// opens, and throws if nothing has been.
    public func run(
        _ request: FogRequest, elevation: Grid<Double>, policy: FetchPolicy = .normal
    ) async throws -> FogReport {
        let bounds = config.bounds
        var warnings: [String] = []
        let clock = ContinuousClock()
        let fetchStarted = clock.now

        // A coarse lattice is enough for the sounding and the surface field;
        // the resolution that matters lives in the DEM, not the forecast.
        let forecastPoints: [ForecastPoint]
        do {
            forecastPoints = try await forecasts.forecastPoints(
                stationLattice(bounds, columns: 5, rows: 5), hourIndex: request.hourIndex,
                includeOptional: true, includeLevels: true, policy: policy)
        } catch {
            throw FogPipelineError.forecastUnavailable("\(error)")
        }
        guard !forecastPoints.isEmpty else {
            throw FogPipelineError.forecastUnavailable("Upstream returned no forecast data")
        }

        if forecastPoints.contains(where: { $0.missing.contains("visibility") }) {
            warnings.append(
                "The upstream model does not publish 'visibility'; fog was diagnosed "
                + "from dewpoint depression and low cloud cover instead.")
        }
        if forecastPoints.allSatisfy({ $0.levels.isEmpty }) {
            warnings.append(
                "No pressure-level temperatures were returned, so the inversion "
                + "could not be located directly.")
        }
        if let fetched = forecastPoints.map(\.fetchedAt).min(),
           now().timeIntervalSince(fetched) > config.forecastCacheTTLSeconds {
            warnings.append(
                "Showing a forecast fetched \(Self.describeAge(now().timeIntervalSince(fetched))) ago: "
                + "a fresh one could not be fetched from Open-Meteo.")
        }

        var stations = forecastPoints.map(forecastFogStation)
        var metarCeilings: [Double] = []
        if request.useObservations && useMetarObservations {
            var metars: [MetarObservation] = []
            do {
                metars = try await observations.observations(
                    stationIDs: metarStationIDs, maxAgeMinutes: metarMaxAgeMinutes, policy: policy)
                if let fetched = metars.compactMap(\.fetchedAt).min(),
                   now().timeIntervalSince(fetched) > config.metarCacheTTLSeconds {
                    warnings.append(
                        "METAR observations were fetched \(Self.describeAge(now().timeIntervalSince(fetched))) "
                        + "ago: fresh ones could not be fetched from the Aviation Weather Center.")
                }
            } catch {
                warnings.append(
                    "Live METAR observations were unavailable (\(error)); the grid is "
                    + "built from model samples only.")
            }
            for metar in metars {
                stations.append(FogStationInput(
                    source: "metar", latitude: metar.latitude, longitude: metar.longitude,
                    elevation: metar.elevationM,
                    fogFraction: observedFogFraction(
                        visibilityM: metar.visibilityM, dewPointDepressionC: metar.dewPointDepressionC,
                        lowCloudFraction: metar.lowCloudFraction, reportsFog: metar.reportsFog,
                        fogVisibilityM: config.fogVisibilityM,
                        fogDewPointDepressionC: config.fogDewPointDepressionC),
                    stationID: metar.stationID, visibilityM: metar.visibilityM,
                    dewPointDepressionC: metar.dewPointDepressionC, cloudBaseM: metar.ceilingM))
                if let ceiling = metar.ceilingM { metarCeilings.append(ceiling) }
            }
        }

        let fetchSeconds = seconds(clock.now - fetchStarted)
        let winds = forecastPoints.compactMap { $0.values["wind_speed_10m"] }.map { $0 * kmhToMs }
        // Only instruments are hard bounds on the slab. Forecast samples are
        // 2-11 km model output: interpolated like any station, but one "clear"
        // sample on a model hillside must not cap the inversion.
        let observed = stations.filter { $0.source == "metar" }
        var slab = diagnoseSlab(
            levelsByPoint: forecastPoints.map(\.levels),
            surfaceValues: forecastPoints.map {
                SurfaceValues(
                    temperature2m: $0.values["temperature_2m"], dewPoint2m: $0.values["dew_point_2m"],
                    boundaryLayerHeight: $0.values["boundary_layer_height"])
            },
            foggedStationElevations: observed.filter(\.isFogged).map(\.elevation),
            observedCeilingsM: metarCeilings,
            clearStationElevations: observed.filter { $0.fogFraction < 0.2 }.map(\.elevation),
            defaultTopM: config.defaultFogTopM,
            meanWindMs: winds.isEmpty ? nil : winds.reduce(0, +) / Double(winds.count))
        if let top = request.fogTopOverrideM { slab = overrideSlabTop(slab, topM: top) }

        var options = FogGridOptions(config: config)
        options.terrainRouting = request.terrainRouting
        options.costBeta = request.costBeta
        options.idwPower = request.idwPower
        options.edgeFeatherM = request.edgeFeatherM ?? config.edgeFeatherM
        let modelStarted = clock.now
        let grid = try await Self.buildOffActor(
            bounds: bounds, elevation: elevation, stations: stations, slab: slab, options: options)

        return FogReport(
            time: forecastPoints[0].time, bounds: bounds, grid: grid, slab: slab,
            method: grid.method, warnings: warnings + grid.warnings,
            fetchSeconds: fetchSeconds, modelSeconds: seconds(clock.now - modelStarted))
    }

    /// Dijkstra over the whole grid is tenths of a second of CPU on every core.
    /// `@concurrent` keeps it off the caller's actor -- the main actor, when a
    /// slider is being dragged.
    @concurrent
    private static func buildOffActor(
        bounds: Bounds, elevation: Grid<Double>, stations: [FogStationInput],
        slab: SlabDiagnosis, options: FogGridOptions
    ) async throws -> FogGridResult {
        try buildFogGrid(bounds: bounds, elevation: elevation, stations: stations, slab: slab, options: options)
    }

    private func forecastFogStation(_ point: ForecastPoint) -> FogStationInput {
        let depression: Double? = {
            guard let t = point.values["temperature_2m"], let td = point.values["dew_point_2m"] else { return nil }
            return t - td
        }()
        return FogStationInput(
            source: "open-meteo", latitude: point.latitude, longitude: point.longitude,
            elevation: point.elevation,
            fogFraction: observedFogFraction(
                visibilityM: point.values["visibility"], dewPointDepressionC: depression,
                lowCloudFraction: point.values["cloud_cover_low"].map { $0 / 100 },
                fogVisibilityM: config.fogVisibilityM,
                fogDewPointDepressionC: config.fogDewPointDepressionC),
            visibilityM: point.values["visibility"],
            relativeHumidity: point.values["relative_humidity_2m"],
            dewPointDepressionC: depression)
    }

    // MARK: - Source status

    /// Probe both upstreams concurrently and report what the model can see.
    /// Neither probe can fail the call: a dead upstream is a degraded source.
    public func sourceStatus() async -> [SourceStatus] {
        async let forecast = probeForecast()
        async let metar = probeMetar()
        return await [forecast, metar]
    }

    private func probeForecast() async -> SourceStatus {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let points = try await forecasts.forecastPoints(
                stationLattice(config.bounds, columns: 2, rows: 2), hourIndex: 0,
                includeOptional: true, includeLevels: true, policy: .normal)
            let missing = Array(Set(points.flatMap(\.missing))).sorted()
            let levels = points.reduce(0) { $0 + $1.levels.count }
            return SourceStatus(
                name: "open-meteo", ok: !points.isEmpty, latencyMs: milliseconds(clock.now - started),
                validTime: points.first?.time, sampleCount: points.count, missingVariables: missing,
                detail: "\(levels) pressure-level samples across \(points.count) points"
                    + (missing.isEmpty ? "" : "; upstream omitted \(missing.joined(separator: ", "))"))
        } catch {
            return SourceStatus(name: "open-meteo", ok: false, detail: "\(error)")
        }
    }

    private func probeMetar() async -> SourceStatus {
        guard useMetarObservations else {
            return SourceStatus(name: "metar", ok: false, detail: "Disabled by configuration.")
        }
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let metars = try await observations.observations(
                stationIDs: metarStationIDs, maxAgeMinutes: metarMaxAgeMinutes, policy: .normal)
            let reporting = metars.map(\.stationID).sorted()
            let silent = Set(metarStationIDs).subtracting(reporting).sorted()
            return SourceStatus(
                name: "metar", ok: !metars.isEmpty, latencyMs: milliseconds(clock.now - started),
                validTime: metars.map(\.observedAt).max(), sampleCount: metars.count, stations: reporting,
                detail: "\(reporting.count) of \(metarStationIDs.count) stations reporting"
                    + (silent.isEmpty ? "" : "; silent: \(silent.joined(separator: ", "))"))
        } catch {
            return SourceStatus(name: "metar", ok: false, detail: "\(error)")
        }
    }

    /// "40 min", "3 h 05 min", "2 days".
    static func describeAge(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "an unknown time" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 48 * 60 { return String(format: "%d h %02d min", minutes / 60, minutes % 60) }
        return "\(minutes / (24 * 60)) days"
    }

    private func seconds(_ duration: Duration) -> Double {
        let (whole, attoseconds) = duration.components
        return Double(whole) + Double(attoseconds) / 1e18
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return (Double(seconds) * 1000 + Double(attoseconds) / 1e15 * 10).rounded() / 10
    }
}

/// The `hourIndex` of `now`. Forecasts are requested with `timezone=UTC`, so
/// the window starts at 00:00 UTC today: index 0 is midnight, not the present.
public func currentHourIndex(now: Date = Date()) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.component(.hour, from: now)
}

/// Evenly spaced coordinates, south-first, row-major. Port of
/// `grid_builder.coordinate_lattice`, used as `station_lattice`.
func stationLattice(_ bounds: Bounds, columns: Int, rows: Int) -> [(latitude: Double, longitude: Double)] {
    (0..<rows).flatMap { y in
        (0..<columns).map { x in
            (bounds.latMin + Double(y) * (bounds.latMax - bounds.latMin) / Double(rows - 1),
             bounds.lonMin + Double(x) * (bounds.lonMax - bounds.lonMin) / Double(columns - 1))
        }
    }
}
