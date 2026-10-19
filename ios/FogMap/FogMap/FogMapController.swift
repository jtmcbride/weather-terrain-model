import FogKit
import FogRender
import MapboxMaps
import UIKit

/// Owns the MapView and the fog layers. Lessons from ios/Spike baked in:
///
/// - The style is loaded *after* observers are attached; an inline style
///   would finish inside MapView's initialiser and never report loaded.
/// - Standard, monochrome theme, dusk preset: white fog vanishes on `light`.
///   Standard's presets light every layer, so the drape is fully emissive or
///   it is darkened into the ground, and `setLights` is never called because
///   it would replace the preset.
/// - Terrain comes from the same Terrarium tiles as the bundled DEM, so the
///   surface the fog is cut against and the surface on screen are one dataset.
/// - Extrusion density lives in lightness: alpha in the colour only darkens.
@MainActor
final class FogMapController {
    enum CameraPreset: String, CaseIterable {
        case headlands, twinPeaks, gate, top

        var title: String {
            switch self {
            case .headlands: "Headlands"
            case .twinPeaks: "Twin Peaks"
            case .gate: "The Gate"
            case .top: "Overhead"
            }
        }

        // The web page's VIEWS.
        var options: CameraOptions {
            switch self {
            case .headlands: camera(37.792, -122.545, zoom: 11.6, pitch: 72, bearing: 34)
            case .twinPeaks: camera(37.752, -122.520, zoom: 12.6, pitch: 74, bearing: 78)
            case .gate: camera(37.806, -122.530, zoom: 12.3, pitch: 70, bearing: 62)
            case .top: camera(37.700, -122.400, zoom: 9.6, pitch: 0, bearing: 0)
            }
        }

        private func camera(_ lat: Double, _ lon: Double, zoom: Double, pitch: Double, bearing: Double) -> CameraOptions {
            CameraOptions(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                          zoom: zoom, bearing: bearing, pitch: pitch)
        }
    }

    let mapView: MapView
    private let store: FogStore
    private var cancelables = Set<AnyCancelable>()
    private var styleReady = false
    private var pendingDrape: (CGImage, Bounds)?
    private var pendingVolume: [VolumeBlock]?
    private var pendingStations: [FogStationInput]?
    private(set) var styleError: String?

    private static let terrainSource = "terrarium"
    private static let fogSource = "fog"
    private static let volumeSource = "fog-volume"
    private static let stationSource = "stations"

    init(store: FogStore, camera: CameraPreset = .headlands) {
        self.store = store
        mapView = MapView(frame: .zero, mapInitOptions: MapInitOptions(cameraOptions: camera.options, styleURI: nil))
        mapView.ornaments.options.scaleBar.visibility = .hidden

        store.onDrape = { [weak self] image, bounds in self?.apply(drape: image, bounds: bounds) }
        store.onVolume = { [weak self] blocks in self?.apply(volume: blocks) }
        store.onStations = { [weak self] stations in self?.apply(stations: stations) }
        store.onRenderMode = { [weak self] mode in self?.apply(mode: mode) }
        store.onExaggeration = { [weak self] value in self?.setExaggeration(value) }
        store.onShowStations = { [weak self] visible in self?.apply(stationsVisible: visible) }

        mapView.gestures.onMapTap.observe { [weak self] context in
            self?.handleTap(context)
        }.store(in: &cancelables)

        mapView.mapboxMap.loadStyle(.standard) { [weak self] error in
            guard let self else { return }
            if let error {
                styleError = "\(error)"
                return
            }
            installLayers()
        }
    }

    /// A tap on a station dot selects the station; anywhere else reads the
    /// grid cell underneath.
    private func handleTap(_ context: InteractionContext) {
        let coordinate = context.coordinate
        guard styleReady, store.showStations else {
            store.inspect(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return
        }
        let hitArea = CGRect(x: context.point.x - 14, y: context.point.y - 14, width: 28, height: 28)
        _ = mapView.mapboxMap.queryRenderedFeatures(
            with: hitArea, options: RenderedQueryOptions(layerIds: ["stations"], filter: nil)
        ) { [weak self] result in
            guard let self else { return }
            if case let .success(hits) = result,
               case let .string(id)? = hits.first?.queriedFeature.feature.properties?["id"] {
                store.select(stationID: id)
            } else {
                store.inspect(latitude: coordinate.latitude, longitude: coordinate.longitude)
            }
        }
    }

    func fly(to preset: CameraPreset) {
        mapView.camera.fly(to: preset.options, duration: 1.6)
    }

    func setExaggeration(_ value: Double) {
        guard styleReady else { return }
        var terrain = Terrain(sourceId: Self.terrainSource)
        terrain.exaggeration = .constant(value)
        try? mapView.mapboxMap.setTerrain(terrain)
    }

    // MARK: - Layers

    private func installLayers() {
        let map = mapView.mapboxMap!
        do {
            try map.setStyleImportConfigProperty(for: "basemap", config: "theme", value: "monochrome")
            try map.setStyleImportConfigProperty(for: "basemap", config: "lightPreset", value: "dusk")
            // Buildings would poke up through a deck that is meant to read as
            // one surface.
            try map.setStyleImportConfigProperty(for: "basemap", config: "show3dObjects", value: false)

            var dem = RasterDemSource(id: Self.terrainSource)
            dem.tiles = ["https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"]
            dem.tileSize = 256
            dem.maxzoom = 14
            dem.encoding = .terrarium
            try map.addSource(dem)

            var image = ImageSource(id: Self.fogSource)
            image.coordinates = corners(.sanFrancisco)
            try map.addSource(image)

            // Fog sits in the `middle` slot: above roads and land, below labels,
            // so the map stays readable through the deck.
            var drape = RasterLayer(id: "fog-drape", source: Self.fogSource)
            drape.slot = .middle
            drape.rasterOpacity = .constant(1)
            drape.rasterResampling = .constant(.linear)
            drape.rasterFadeDuration = .constant(0)
            drape.rasterEmissiveStrength = .constant(1)
            try map.addLayer(drape)

            var volume = GeoJSONSource(id: Self.volumeSource)
            volume.data = .featureCollection(FeatureCollection(features: []))
            try map.addSource(volume)

            var extrusion = FillExtrusionLayer(id: "fog-volume", source: Self.volumeSource)
            extrusion.slot = .middle
            // Thin fog is a dim grey that recedes into the hillside; dense fog
            // is near-white. Lightness, not alpha.
            extrusion.fillExtrusionColor = .expression(Exp(.interpolate) {
                Exp(.linear)
                Exp(.get) { "f" }
                0.05; UIColor(red: 0.725, green: 0.776, blue: 0.804, alpha: 1)
                0.35; UIColor(red: 0.831, green: 0.871, blue: 0.890, alpha: 1)
                0.7; UIColor(red: 0.918, green: 0.945, blue: 0.957, alpha: 1)
                1.0; UIColor(red: 0.984, green: 0.992, blue: 0.996, alpha: 1)
            })
            // Height above the terrain, so `top - ground` puts every roof at
            // the inversion.
            extrusion.fillExtrusionHeight = .expression(Exp(.get) { "h" })
            extrusion.fillExtrusionBase = .constant(0)
            extrusion.fillExtrusionOpacity = .constant(0.62)
            extrusion.fillExtrusionVerticalGradient = .constant(false)
            // Mostly self-lit so dusk does not turn the deck to slate, but not
            // fully, so the walls keep enough shading to read as volume.
            extrusion.fillExtrusionEmissiveStrength = .constant(0.7)
            try map.addLayer(extrusion)

            var stations = GeoJSONSource(id: Self.stationSource)
            stations.data = .featureCollection(FeatureCollection(features: []))
            try map.addSource(stations)

            var dots = CircleLayer(id: "stations", source: Self.stationSource)
            dots.slot = .top
            dots.circleRadius = .constant(6)
            dots.circleColor = .expression(Exp(.switchCase) {
                Exp(.get) { "fogged" }
                UIColor(red: 0.29, green: 0.416, blue: 0.478, alpha: 1)
                UIColor(red: 0.82, green: 0.6, blue: 0, alpha: 1)
            })
            dots.circleStrokeColor = .constant(StyleColor(.white))
            dots.circleStrokeWidth = .constant(2)
            dots.circleEmissiveStrength = .constant(1)
            try map.addLayer(dots)

            styleReady = true
            setExaggeration(store.exaggeration)
            apply(stationsVisible: store.showStations)
            apply(mode: store.renderMode)
            if let (image, bounds) = pendingDrape { apply(drape: image, bounds: bounds) }
            if let blocks = pendingVolume { apply(volume: blocks) }
            if let stations = pendingStations { apply(stations: stations) }
        } catch {
            styleError = "layer setup: \(error)"
        }
    }

    /// Image-source corners, north-first: TL, TR, BR, BL as [lon, lat].
    private func corners(_ bounds: Bounds) -> [[Double]] {
        [[bounds.lonMin, bounds.latMax], [bounds.lonMax, bounds.latMax],
         [bounds.lonMax, bounds.latMin], [bounds.lonMin, bounds.latMin]]
    }

    private func apply(drape image: CGImage, bounds: Bounds) {
        guard styleReady else { pendingDrape = (image, bounds); return }
        pendingDrape = nil
        try? mapView.mapboxMap.updateImageSource(withId: Self.fogSource, image: UIImage(cgImage: image))
    }

    private func apply(volume blocks: [VolumeBlock]) {
        guard styleReady else { pendingVolume = blocks; return }
        pendingVolume = nil
        let features = blocks.map { block -> Feature in
            let ring = [
                CLLocationCoordinate2D(latitude: block.north, longitude: block.west),
                CLLocationCoordinate2D(latitude: block.north, longitude: block.east),
                CLLocationCoordinate2D(latitude: block.south, longitude: block.east),
                CLLocationCoordinate2D(latitude: block.south, longitude: block.west),
                CLLocationCoordinate2D(latitude: block.north, longitude: block.west),
            ]
            var feature = Feature(geometry: .polygon(Polygon([ring])))
            feature.properties = ["f": .number(block.fog), "h": .number(block.height)]
            return feature
        }
        mapView.mapboxMap.updateGeoJSONSource(
            withId: Self.volumeSource, geoJSON: .featureCollection(FeatureCollection(features: features)))
    }

    private func apply(stations: [FogStationInput]) {
        guard styleReady else { pendingStations = stations; return }
        pendingStations = nil
        let features = stations.map { station -> Feature in
            var feature = Feature(geometry: .point(Point(
                CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude))))
            feature.properties = ["fogged": .boolean(station.isFogged), "id": .string(station.stationID ?? "")]
            return feature
        }
        mapView.mapboxMap.updateGeoJSONSource(
            withId: Self.stationSource, geoJSON: .featureCollection(FeatureCollection(features: features)))
    }

    private func apply(stationsVisible visible: Bool) {
        guard styleReady else { return }
        try? mapView.mapboxMap.setLayerProperty(
            for: "stations", property: "visibility", value: visible ? "visible" : "none")
    }

    private func apply(mode: RenderMode) {
        guard styleReady else { return }
        try? mapView.mapboxMap.setLayerProperty(
            for: "fog-drape", property: "visibility", value: mode.showsDrape ? "visible" : "none")
        try? mapView.mapboxMap.setLayerProperty(
            for: "fog-volume", property: "visibility", value: mode.showsVolume ? "visible" : "none")
    }
}
