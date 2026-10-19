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

    // Outputs.
    private(set) var report: FogReport?
    private(set) var isLoading = false
    private(set) var failure: String?
    var readout: Readout?

    // The map controller's hooks.
    @ObservationIgnored var onDrape: ((CGImage, Bounds) -> Void)?
    @ObservationIgnored var onVolume: (([VolumeBlock]) -> Void)?
    @ObservationIgnored var onStations: (([FogStationInput]) -> Void)?
    @ObservationIgnored var onRenderMode: ((RenderMode) -> Void)?

    @ObservationIgnored private let pipeline = FogPipeline()
    @ObservationIgnored private var elevations: [GridPreset: Grid<Double>] = [:]
    @ObservationIgnored private var field: FogField?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var paintTask: Task<Void, Never>?

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

    private func run() async {
        isLoading = true
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let elevation = try loadElevation(gridPreset)
            var request = FogRequest()
            request.hourIndex = hourIndex
            request.terrainRouting = terrainRouting
            request.fogTopOverrideM = fogTopOverrideM
            request.edgeFeatherM = edgeFeatherM
            let report = try await pipeline.run(request, elevation: elevation)
            guard !Task.isCancelled else { return }
            self.report = report
            failure = nil
            readout = nil
            onStations?(report.grid.usedStations.filter { $0.source == "metar" })
            await prepareAndPaint(report)
        } catch {
            guard !Task.isCancelled else { return }
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

    /// The grid cell under a tapped coordinate, read straight from the report.
    func inspect(latitude: Double, longitude: Double) {
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
