import FogKit
import MapboxMaps
import SwiftUI

@main
struct FogMapApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Phase 3: the map rendering live FogKit output, with just enough controls to
/// exercise re-run versus repaint. The full control sheet is phase 4.
///
/// Launch arguments set initial state for unattended screenshots:
/// `-camera headlands|twinPeaks|gate|top -mode drape|volume|both -fogTop M
/// -billow X -grid 0-4 -hour N -hideControls YES`.
struct ContentView: View {
    @State private var store: FogStore
    @State private var map: FogMapController
    private let hideControls: Bool

    init() {
        let args = UserDefaults.standard
        let store = FogStore()
        if let mode = args.string(forKey: "mode").flatMap(RenderMode.init) { store.renderMode = mode }
        if args.object(forKey: "fogTop") != nil { store.fogTopOverrideM = args.double(forKey: "fogTop") }
        if args.object(forKey: "billow") != nil { store.billow = args.double(forKey: "billow") }
        if args.object(forKey: "grid") != nil,
           let preset = GridPreset(rawValue: args.integer(forKey: "grid")) { store.gridPreset = preset }
        if args.object(forKey: "hour") != nil { store.hourIndex = args.integer(forKey: "hour") }
        let camera = args.string(forKey: "camera").flatMap(FogMapController.CameraPreset.init) ?? .headlands
        _store = State(initialValue: store)
        _map = State(initialValue: FogMapController(store: store, camera: camera))
        hideControls = args.bool(forKey: "hideControls")
        store.refresh()
    }

    var body: some View {
        ZStack {
            MapContainer(mapView: map.mapView).ignoresSafeArea()
            VStack(spacing: 8) {
                StatusPanel(store: store)
                if let readout = store.readout { ReadoutPanel(readout: readout) }
                Spacer()
                if !hideControls { Controls(store: store, map: map) }
            }
            .padding()
        }
    }
}

struct MapContainer: UIViewRepresentable {
    let mapView: MapView
    func makeUIView(context: Context) -> MapView { mapView }
    func updateUIView(_ uiView: MapView, context: Context) {}
}

private struct StatusPanel: View {
    let store: FogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if store.isLoading { ProgressView().controlSize(.small) }
                Text(title).font(.subheadline.weight(.semibold))
            }
            if let slab = store.report?.slab {
                Text("Fog top \(Int(slab.topM)) m · base \(Int(slab.baseM)) m · \(slab.blockingRegime.rawValue)")
            }
            if let report = store.report {
                Text(String(format: "model %.2f s · fetch %.2f s · %@",
                            report.modelSeconds, report.fetchSeconds, store.gridPreset.label))
                    .foregroundStyle(.secondary)
            }
            if let failure = store.failure {
                Text(failure).foregroundStyle(.red).lineLimit(3)
            } else if let warnings = store.report?.warnings, !warnings.isEmpty {
                Text("\(warnings.count) warning(s): \(warnings[0])").foregroundStyle(.orange).lineLimit(2)
            }
        }
        .font(.caption)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        guard let time = store.report?.time else { return store.isLoading ? "Fetching fog…" : "No data" }
        return "Hour \(store.hourIndex) · \(time) UTC"
    }
}

private struct ReadoutPanel: View {
    let readout: Readout

    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.subheadline.weight(.semibold))
            Text("\(Int(readout.elevationM)) m")
            Text(String(format: "fog %.0f%%", readout.fogFraction * 100))
            Text(String(format: "vis %.1f km", readout.visibilityM / 1000))
        }
        .font(.caption)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: String {
        switch readout.state {
        case .inFog: "In fog"
        case .aboveDeck: "Above the deck"
        case .underDeck: "Under the deck"
        case .clear: "Clear"
        }
    }
}

private struct Controls: View {
    @Bindable var store: FogStore
    let map: FogMapController

    var body: some View {
        VStack(spacing: 8) {
            Picker("Render", selection: $store.renderMode) {
                ForEach(RenderMode.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Button { store.hourIndex = max(0, store.hourIndex - 1) } label: { Image(systemName: "chevron.left") }
                Text("Hour \(store.hourIndex)").monospacedDigit().frame(maxWidth: .infinity)
                Button { store.hourIndex = min(167, store.hourIndex + 1) } label: { Image(systemName: "chevron.right") }
            }

            slider("Fog top", value: Binding(
                get: { store.fogTopOverrideM ?? store.report?.slab.topM ?? 300 },
                set: { store.fogTopOverrideM = $0 }), range: 0...800, step: 10,
                   text: store.fogTopOverrideM.map { "\(Int($0)) m" } ?? "auto")
            slider("Billow", value: $store.billow, range: 0...1, step: 0.05,
                   text: store.billow == 0 ? "off (level set)" : String(format: "%.2f", store.billow))
            slider("Density", value: $store.density, range: 0.05...1, step: 0.05,
                   text: String(format: "%.2f", store.density))

            HStack {
                ForEach(FogMapController.CameraPreset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) { map.fly(to: preset) }.font(.caption)
                }
                Spacer()
                Button("Auto top") { store.fogTopOverrideM = nil }.font(.caption)
            }
        }
        .font(.callout)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func slider(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(title); Spacer(); Text(text).monospacedDigit().foregroundStyle(.secondary) }
                .font(.caption)
            Slider(value: value, in: range, step: step)
        }
    }
}
