import MapboxMaps
import SwiftUI

@main
struct FogSpikeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var spike = SpikeController()

    var body: some View {
        ZStack {
            MapContainer(mapView: spike.mapView).ignoresSafeArea()
            VStack {
                HUD(spike: spike)
                Spacer()
                // `-hideControls YES` clears the map for unattended screenshots.
                if !UserDefaults.standard.bool(forKey: "hideControls") {
                    Controls(spike: spike)
                }
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

private struct HUD: View {
    let spike: SpikeController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(spike.styleStatus)
            if spike.mode == .drape {
                Text("image render \(ms(spike.imageRenderMs)) · update \(ms(spike.imageUpdateMs))")
            } else {
                Text("\(spike.volumeFeatures) columns · build \(ms(spike.volumeBuildMs)) · ready \(ms(spike.volumeReadyMs))")
            }
            Text("render \(spike.fps.map { String(format: "%.0f fps", $0) } ?? "–")\(spike.orbiting ? " (orbiting)" : "")")
            if let error = spike.lastError {
                Text(error).foregroundStyle(.red).lineLimit(3)
            }
        }
        .font(.caption.monospaced())
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ms(_ value: Double?) -> String {
        value.map { String(format: "%.1f ms", $0) } ?? "–"
    }
}

private struct Controls: View {
    @Bindable var spike: SpikeController

    var body: some View {
        VStack(spacing: 8) {
            Picker("Mode", selection: $spike.mode) {
                ForEach(SpikeController.Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .onChange(of: spike.mode) { spike.applyMode() }

            labeled("Fog top \(Int(spike.topM)) m") {
                Slider(value: $spike.topM, in: 0...600, step: 10)
                    .onChange(of: spike.topM) { spike.refreshFog() }
            }
            labeled(String(format: "Exaggeration %.1f×", spike.exaggeration)) {
                Slider(value: $spike.exaggeration, in: 1...3, step: 0.1)
                    .onChange(of: spike.exaggeration) { spike.applyTerrain() }
            }

            if spike.mode == .drape {
                labeled(String(format: "Density %.2f", spike.density)) {
                    Slider(value: $spike.density, in: 0.05...1, step: 0.05)
                        .onChange(of: spike.density) { spike.refreshFog() }
                }
                Toggle("Alignment markers", isOn: $spike.cornerMarker)
                    .onChange(of: spike.cornerMarker) {
                        spike.applyReferenceVisibility()
                        spike.refreshFog()
                    }
            } else {
                Picker("Columns", selection: $spike.volumeBudget) {
                    Text("5k").tag(5_000)
                    Text("12k").tag(12_000)
                    Text("25k").tag(25_000)
                    Text("all").tag(256 * 280)
                }
                .pickerStyle(.segmented)
                .onChange(of: spike.volumeBudget) { spike.refreshFog() }
                Toggle("Alpha test (red @ 8% alpha)", isOn: $spike.alphaTest)
                    .onChange(of: spike.alphaTest) { spike.applyExtrusionColor() }
                Picker("Lighting", selection: $spike.lighting) {
                    ForEach(SpikeController.Lighting.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: spike.lighting) { spike.applyLighting() }
            }

            Button(spike.orbiting ? "Stop orbit" : "Orbit (measure fps)") { spike.toggleOrbit() }
                .buttonStyle(.bordered)
        }
        .font(.callout)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption)
            content()
        }
    }
}
