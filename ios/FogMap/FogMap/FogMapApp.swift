import FogKit
import MapboxMaps
import SwiftUI

@main
struct FogMapApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// A full-screen map under a persistent sheet, the Apple Maps arrangement:
/// the map stays interactive while the sheet is collapsed or at medium height.
///
/// Launch arguments set initial state for unattended screenshots:
/// `-camera headlands|twinPeaks|gate|top -mode drape|volume|both -fogTop M
/// -billow X -grid 0-4 -hour N -sheet peek|medium|large -hideControls YES`.
struct ContentView: View {
    @State private var store: FogStore
    @State private var map: FogMapController
    @State private var detent: PresentationDetent
    private let hideControls: Bool

    /// Collapsed: the timeline and nothing else.
    private static let peek = PresentationDetent.height(104)

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
        let detent: PresentationDetent = switch args.string(forKey: "sheet") {
        case "medium": .medium
        case "large": .large
        default: Self.peek
        }
        _detent = State(initialValue: detent)
        hideControls = args.bool(forKey: "hideControls")
        // Sources are probed on demand, not at launch: the probe is its own
        // upstream request, and Open-Meteo weights a multi-variable call as
        // dozens against a per-minute limit.
        store.refresh()
    }

    var body: some View {
        ZStack(alignment: .top) {
            MapContainer(mapView: map.mapView).ignoresSafeArea()
            VStack(spacing: 8) {
                if let station = store.selectedStation {
                    StationCard(station: station) { store.selectedStation = nil }
                } else if let readout = store.readout {
                    ReadoutCard(readout: readout) { store.readout = nil }
                }
            }
            .padding(.horizontal)
            .animation(.snappy, value: store.readout)
            .animation(.snappy, value: store.selectedStation)
        }
        .sheet(isPresented: .constant(!hideControls)) {
            ControlSheet(store: store, map: map)
                .presentationDetents([Self.peek, .medium, .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationContentInteraction(.scrolls)
                .presentationCornerRadius(20)
                .interactiveDismissDisabled()
        }
    }
}

struct MapContainer: UIViewRepresentable {
    let mapView: MapView
    func makeUIView(context: Context) -> MapView { mapView }
    func updateUIView(_ uiView: MapView, context: Context) {}
}

/// What a person standing in the tapped cell would experience.
private struct ReadoutCard: View {
    let readout: Readout
    let dismiss: () -> Void

    var body: some View {
        Card(dismiss: dismiss) {
            Text(title).font(.headline)
            HStack(spacing: 14) {
                Text("\(Int(readout.elevationM)) m")
                Text(String(format: "fog %.0f%%", readout.fogFraction * 100))
                Text(visibility)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch readout.state {
        case .inFog: "In fog"
        case .aboveDeck: "Above the deck, in sun"
        case .underDeck: "Under the deck: grey, but clear"
        case .clear: "Clear"
        }
    }

    private var visibility: String {
        readout.visibilityM >= 10_000
            ? String(format: "vis %.0f km", readout.visibilityM / 1000)
            : String(format: "vis %.1f km", readout.visibilityM / 1000)
    }
}

private struct StationCard: View {
    let station: FogStationInput
    let dismiss: () -> Void

    var body: some View {
        Card(dismiss: dismiss) {
            HStack {
                Text(station.stationID ?? "Station").font(.headline)
                Text(station.isFogged ? "Fogged" : "Clear")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(station.isFogged ? Color.gray.opacity(0.3) : Color.yellow.opacity(0.3), in: Capsule())
            }
            HStack(spacing: 14) {
                Text(station.visibilityM.map { String(format: "vis %.1f km", $0 / 1000) } ?? "no visibility report")
                if let ceiling = station.cloudBaseM { Text("ceiling \(Int(ceiling)) m") }
                Text("elev \(Int(station.elevation)) m")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

private struct Card<Content: View>: View {
    let dismiss: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) { content }
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
