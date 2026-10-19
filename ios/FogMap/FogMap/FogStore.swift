import CoreGraphics
import FogKit
import FogRender
import Foundation
import Observation

enum RenderMode: String, CaseIterable, Identifiable {
    case drape, volume, both
    var id: String { rawValue }
    var showsDrape: Bool { self != .volume }
    var showsVolume: Bool { self != .drape }
}

/// What a tap on the map reports: what a person standing there experiences.
struct Readout: Equatable {
    var state: SurfaceState
    var elevationM: Double
    var fogFraction: Double
    var visibilityM: Double
}

/// App state, and the split the web page makes between controls that re-run
/// the model and controls that only repaint.
///
/// Model inputs (hour, grid, routing, fog top, feather) re-run FogPipeline,
/// debounced and cancelling any run in flight. Render inputs (density, billow,
/// detail) repaint from the cached report: the model's answer does not change,
/// so it is not recomputed.
@MainActor
@Observable
final class FogStore {
    // Model inputs.
    var hourIndex = currentHourIndex() { didSet { refresh() } }
    var gridPreset = GridPreset.standard { didSet { refresh() } }
    var terrainRouting = true { didSet { refresh() } }
    var fogTopOverrideM: Double? { didSet { refresh() } }
    /// Metres of hillside over which fog thins. A model parameter, not a render
    /// trick; 60 m is the web page's default.
    var edgeFeatherM = 60.0 { didSet { refresh() } }

    // Render inputs.
    var renderMode = RenderMode.drape { didSet { onRenderMode?(renderMode) } }
    /// Real marine fog is not opaque paint; the hillside should read through.
    var density = 0.5 { didSet { repaint(drape: true, volume: false) } }
    /// Amplitude of the render-only texture. 0 shows the level set exactly.
    var billow = 0.65 { didSet { repaint(drape: true, volume: true) } }
    /// Bitmap pixels per grid cell. Adds smoothness, never information.
    var detail = 3 { didSet { reprepare() } }
    var exaggeration = 1.4 { didSet { onExaggeration?(exaggeration) } }
    var showStations = true { didSet { onShowStations?(showStations) } }

    // Timeline playback: one forecast hour per tick. Scrubbing is cheap because
    // the forecast is cached for the whole window; each hour is a model run.
    private(set) var isPlaying = false
    @ObservationIgnored private var playTask: Task<Void, Never>?
    static let playInterval = Duration.milliseconds(1800)
    static let lastHour = 167

    // Outputs.
    private(set) var report: FogReport?
    private(set) var isLoading = false
    private(set) var failure: String?
    var readout: Readout?
    /// A tapped METAR station, shown in place of the cell readout.
    var selectedStation: FogStationInput?
    private(set) var sources: [SourceStatus] = []
    private(set) var isCheckingSources = false

    // The map controller's hooks.
    @ObservationIgnored var onDrape: ((CGImage, Bounds) -> Void)?
    @ObservationIgnored var onVolume: (([VolumeBlock]) -> Void)?
    @ObservationIgnored var onStations: (([FogStationInput]) -> Void)?
    @ObservationIgnored var onRenderMode: ((RenderMode) -> Void)?
    @ObservationIgnored var onExaggeration: ((Double) -> Void)?
    @ObservationIgnored var onShowStations: ((Bool) -> Void)?

    @ObservationIgnored private let pipeline = FogPipeline()
    /// Never touch the network: draw only what the disk cache holds. For
    /// development, where a dozen relaunches would otherwise spend Open-Meteo's
    /// per-minute limit (`-offline YES`).
    @ObservationIgnored var offline = false
    @ObservationIgnored private var elevations: [GridPreset: Grid<Double>] = [:]
    @ObservationIgnored private var field: FogField?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var paintTask: Task<Void, Never>?

    /// First draw: the last cached forecast immediately, with no network,
    /// then a normal run that refreshes it. On a cold start with nothing
    /// cached, the first step simply finds nothing and the second does the work.
    func start() {
        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.run(policy: .cacheOnly)
            guard !Task.isCancelled else { return }
            await self?.run(policy: .normal)
        }
    }

    /// Re-run the model, debounced: a slider drag produces one run when it
    /// settles, not one per tick.
    func refresh() {
        runTask?.cancel()
        runTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    private func run(policy requested: FetchPolicy = .normal) async {
        let policy = offline ? .cacheOnly : requested
        isLoading = true
        defer { if !Task.isCancelled && requested == .normal { isLoading = false } }
        do {
            let elevation = try loadElevation(gridPreset)
            var request = FogRequest()
            request.hourIndex = hourIndex
            request.terrainRouting = terrainRouting
            request.fogTopOverrideM = fogTopOverrideM
            request.edgeFeatherM = edgeFeatherM
            let report = try await pipeline.run(request, elevation: elevation, policy: policy)
            guard !Task.isCancelled else { return }
            self.report = report
            failure = nil
            readout = nil
            if let id = selectedStation?.stationID {
                selectedStation = report.grid.usedStations.first { $0.stationID == id }
            }
            onStations?(report.grid.usedStations.filter { $0.source == "metar" })
            await prepareAndPaint(report)
        } catch {
            // Nothing cached is not a failure; the normal run follows.
            guard !Task.isCancelled, requested == .normal else { return }
            failure = "\(error)"
        }
    }

    private func loadElevation(_ preset: GridPreset) throws -> Grid<Double> {
        if let cached = elevations[preset] { return cached }
        let grid = try preset.elevation()
        elevations[preset] = grid
        return grid
    }

    /// The resample is the expensive half of painting and depends only on the
    /// report and the detail setting, so it is cached in `field`.
    private func prepareAndPaint(_ report: FogReport) async {
        let fog = report.grid.fogFraction, bounds = report.bounds, detail = self.detail
        field = await Task.detached(priority: .userInitiated) {
            FogTexture.prepare(fog, bounds: bounds, detail: detail)
        }.value
        repaint(drape: true, volume: true)
    }

    private func reprepare() {
        guard let report else { return }
        paintTask?.cancel()
        paintTask = Task { await prepareAndPaint(report) }
    }

    /// Repaint from the cached field and report, coalescing rapid slider ticks.
    private func repaint(drape: Bool, volume: Bool) {
        guard let report, let field else { return }
        let density = self.density, billow = self.billow
        paintTask?.cancel()
        paintTask = Task { [weak self] in
            if drape {
                let image = await Task.detached(priority: .userInitiated) {
                    FogTexture.render(field, density: density, billow: billow)
                }.value
                guard !Task.isCancelled else { return }
                self?.onDrape?(image, report.bounds)
            }
            if volume {
                let blocks = await Task.detached(priority: .userInitiated) {
                    FogVolume.blocks(
                        fog: report.grid.fogFraction, elevation: report.grid.elevation,
                        bounds: report.bounds, topM: report.slab.topM, billow: billow)
                }.value
                guard !Task.isCancelled else { return }
                self?.onVolume?(blocks)
            }
        }
    }

    // MARK: - Timeline

    func togglePlay() {
        if isPlaying { stopPlaying() } else { startPlaying() }
    }

    private func startPlaying() {
        isPlaying = true
        playTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.playInterval)
                guard let self, !Task.isCancelled else { return }
                hourIndex = hourIndex >= Self.lastHour ? 0 : hourIndex + 1
            }
        }
    }

    func stopPlaying() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
    }

    /// The local wall-clock time of a forecast hour. Index 0 is 00:00 UTC on
    /// the day the window was requested.
    func date(forHour hour: Int) -> Date {
        if let time = report?.time, let reported = Self.utcFormatter.date(from: time) {
            return reported.addingTimeInterval(Double(hour - hourIndex) * 3600)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.startOfDay(for: Date()).addingTimeInterval(Double(hour) * 3600)
    }

    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter
    }()

    // MARK: - Sources

    /// Probe both upstreams: is real data arriving, how old is it, which
    /// fallback is in play. A dead upstream is a status, never an error.
    func checkSources() {
        guard !isCheckingSources else { return }
        isCheckingSources = true
        Task {
            sources = await pipeline.sourceStatus()
            isCheckingSources = false
        }
    }

    // MARK: - Inspection

    func select(stationID: String) {
        selectedStation = report?.grid.usedStations.first { $0.stationID == stationID }
        readout = nil
    }

    /// The grid cell under a tapped coordinate, read straight from the report.
    func inspect(latitude: Double, longitude: Double) {
        selectedStation = nil
        guard let grid = report?.grid, let bounds = report?.bounds else { return }
        let geometry = RasterGeometry(bounds: bounds, gridX: grid.fogFraction.width, gridY: grid.fogFraction.height)
        guard let cell = geometry.cellIndex(latitude: latitude, longitude: longitude) else {
            readout = nil
            return
        }
        readout = Readout(
            state: grid.surfaceState.values[cell], elevationM: grid.elevation.values[cell],
            fogFraction: grid.fogFraction.values[cell], visibilityM: grid.visibilityM.values[cell])
    }
}
