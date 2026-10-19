import FogKit
import SwiftUI

/// The persistent bottom sheet. Collapsed it is a timeline; at medium height
/// the controls from fog-map.html; at full height the slab readout, live
/// sources and warnings -- so the model explains itself.
struct ControlSheet: View {
    @Bindable var store: FogStore
    let map: FogMapController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TimelineSection(store: store)
                FogSection(store: store)
                ModelSection(store: store)
                MapSection(store: store, map: map)
                SlabSection(store: store)
                SourcesSection(store: store)
            }
            .padding(.horizontal)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.basedOnSize)
        // `-sheetScroll bottom`, for screenshots of the readouts.
        .defaultScrollAnchor(UserDefaults.standard.string(forKey: "sheetScroll") == "bottom" ? .bottom : .top)
    }
}

// MARK: - Timeline

private struct TimelineSection: View {
    @Bindable var store: FogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button(action: store.togglePlay) {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                        .background(.tint.opacity(0.15), in: Circle())
                }
                .accessibilityLabel(store.isPlaying ? "Pause" : "Play")
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.date(forHour: store.hourIndex), format: .dateTime.weekday(.abbreviated).hour().minute())
                        .font(.headline)
                    // One line, so a long error cannot push the collapsed
                    // sheet's content; the full text is in the readout below.
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if store.isLoading { ProgressView() }
                Button("Now") { store.hourIndex = currentHourIndex() }
                    .font(.callout)
                    .disabled(store.hourIndex == currentHourIndex())
            }
            // No `step:`: iOS draws a tick per step, and 168 of them merge into
            // a second track. The binding quantises instead.
            Slider(
                value: Binding(get: { Double(store.hourIndex) }, set: { store.hourIndex = Int($0.rounded()) }),
                in: 0...Double(FogStore.lastHour)
            ) { Text("Forecast hour") } onEditingChanged: { editing in
                if editing { store.stopPlaying() }
            }
        }
    }

    private var subtitle: String {
        var parts = ["hour \(store.hourIndex) of \(FogStore.lastHour)"]
        if let slab = store.report?.slab {
            parts.append(slab.baseM >= slab.topM ? "no deck" : "deck \(Int(slab.baseM))–\(Int(slab.topM)) m")
        }
        if let failure = store.failure { parts.append(failure) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Controls

private struct FogSection: View {
    @Bindable var store: FogStore

    var body: some View {
        SheetSection("Fog") {
            Picker("Render", selection: $store.renderMode) {
                ForEach(RenderMode.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledSlider("Density", value: $store.density, in: 0.05...1, step: 0.05,
                          text: String(format: "%.2f", store.density))
            LabeledSlider("Billow texture", value: $store.billow, in: 0...1, step: 0.05,
                          text: store.billow == 0 ? "off (level set)" : String(format: "%.2f", store.billow))
            Stepper(value: $store.detail, in: 1...5) {
                HStack {
                    Text("Render detail")
                    Spacer()
                    Text("\(store.detail)×").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Footnote("Density, billow and detail are rendering only: they repaint the model's answer, never change it. Billow off shows the level set exactly.")
        }
    }
}

private struct ModelSection: View {
    @Bindable var store: FogStore

    var body: some View {
        SheetSection("Model") {
            Toggle("Diagnose fog top", isOn: Binding(
                get: { store.fogTopOverrideM == nil },
                set: { store.fogTopOverrideM = $0 ? nil : (store.report?.slab.topM ?? 300).rounded() }))
            if let top = store.fogTopOverrideM {
                LabeledSlider("Fog top", value: Binding(get: { top }, set: { store.fogTopOverrideM = $0 }),
                              in: 0...800, step: 10, text: "\(Int(top)) m")
                Footnote("Drag through ~280 m and the deck swallows Twin Peaks.")
            }
            Toggle("Terrain routing", isOn: $store.terrainRouting)
            if !store.terrainRouting {
                Footnote("Straight-line weighting: fog walks through ridges. Included for comparison.")
            }
            LabeledContent("Grid") {
                Picker("Grid", selection: $store.gridPreset) {
                    ForEach(GridPreset.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }
            LabeledSlider("Edge softness", value: $store.edgeFeatherM, in: 0...150, step: 5,
                          text: "\(Int(store.edgeFeatherM)) m")
        }
    }
}

private struct MapSection: View {
    @Bindable var store: FogStore
    let map: FogMapController

    var body: some View {
        SheetSection("Map") {
            LabeledSlider("Terrain exaggeration", value: $store.exaggeration, in: 1...3, step: 0.1,
                          text: String(format: "%.1f×", store.exaggeration))
            Toggle("METAR stations", isOn: $store.showStations)
            HStack {
                ForEach(FogMapController.CameraPreset.allCases, id: \.self) { preset in
                    Button(preset.title) { map.fly(to: preset) }
                        .buttonStyle(.bordered)
                        .font(.caption)
                }
            }
        }
    }
}

// MARK: - Readouts

private struct SlabSection: View {
    let store: FogStore

    var body: some View {
        SheetSection("Marine layer") {
            if let report = store.report {
                let slab = report.slab
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    stat("Fog top (H)", metres(slab.topM))
                    stat("Cloud base (B)", metres(slab.baseM))
                    stat("Inversion base", metres(slab.inversionBaseM))
                    stat("Inversion strength", slab.inversionStrengthC.map { String(format: "%.1f °C", $0) } ?? "—")
                    stat("LCL", metres(slab.lclM))
                    stat("Froude number", slab.froudeNumber.map { String(format: "%.2f", $0) } ?? "—")
                    stat("Flow regime", slab.blockingRegime == .unknown ? "—" : slab.blockingRegime.rawValue)
                    stat("Valid", "\(report.time) UTC")
                    stat("Stations", "\(report.grid.usedStations.count)")
                    stat("Model", String(format: "%.2f s · fetch %.2f s", report.modelSeconds, report.fetchSeconds))
                }
                .font(.callout)
                Footnote(slab.source)
                if !report.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } else {
                Text(store.failure ?? "Waiting for the first grid…").foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private func metres(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) m" } ?? "—"
    }
}

private struct SourcesSection: View {
    let store: FogStore

    var body: some View {
        SheetSection("Live sources") {
            ForEach(store.sources, id: \.name) { source in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Circle().fill(source.ok ? .green : .red).frame(width: 8, height: 8)
                        Text(source.name).font(.callout.weight(.medium))
                        Spacer()
                        if let latency = source.latencyMs {
                            Text("\(Int(latency)) ms").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(source.detail).font(.caption).foregroundStyle(.secondary)
                    if let valid = source.validTime {
                        Text("valid \(valid)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Button(store.isCheckingSources ? "Checking…" : "Check sources", action: store.checkSources)
                .disabled(store.isCheckingSources)
        }
    }
}

// MARK: - Building blocks

private struct SheetSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            content
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, text: String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                Spacer()
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }
            // Quantised in the binding rather than with `step:`, which makes
            // iOS draw a row of tick marks under every slider.
            Slider(value: Binding(
                get: { value },
                set: { value = min(max(($0 / step).rounded() * step, range.lowerBound), range.upperBound) }
            ), in: range) { Text(title) }
        }
    }
}

private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
