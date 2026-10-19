import MapboxMaps
import Observation
import QuartzCore
import UIKit

/// Owns the MapView and runs each phase-0 check against it.
@MainActor
@Observable
final class SpikeController {
    enum Mode: String, CaseIterable { case drape, volume }
    enum Lighting: String, CaseIterable { case flat, threeD = "3D" }

    // Controls
    var mode: Mode = .drape
    var topM: Float = 250
    var exaggeration: Double = 1.4
    var density: Float = 0.5
    var volumeBudget = 12_000
    var cornerMarker = false
    var alphaTest = false
    var lighting: Lighting = .flat
    private(set) var orbiting = false

    // Measurements
    private(set) var styleStatus = "loading style…"
    private(set) var imageRenderMs: Double?
    private(set) var imageUpdateMs: Double?
    private(set) var volumeFeatures = 0
    private(set) var volumeBuildMs: Double?
    private(set) var volumeReadyMs: Double?
    private(set) var fps: Double?
    private(set) var lastError: String?

    @ObservationIgnored let mapView: MapView
    @ObservationIgnored private let elevation = Elevation.load(width: 256, height: 280)
    @ObservationIgnored private var cancelables = Set<AnyCancelable>()
    @ObservationIgnored private var styleReady = false
    @ObservationIgnored private var volumeSentAt: [String: CFTimeInterval] = [:]
    @ObservationIgnored private var volumeSequence = 0
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var fpsWindowStart = CACurrentMediaTime()
    @ObservationIgnored private var orbitLink: CADisplayLink?

    private static let terrainSource = "terrarium"
    private static let fogSource = "fog"
    private static let volumeSource = "fog-volume"
    // Darker than the real basemap so white fog is legible in screenshots.
    private static let offlineStyle = """
        {"version": 8, "sources": {},
         "layers": [{"id": "bg", "type": "background", "paint": {"background-color": "#7d8a91"}}]}
        """
    private static let cameraPresets: [String: CameraOptions] = [
        // Whole domain from straight above: for the corner-order check.
        "overview": CameraOptions(
            center: CLLocationCoordinate2D(latitude: 37.695, longitude: -122.40),
            zoom: 8.6, bearing: 0, pitch: 0),
        "oblique": CameraOptions(
            center: CLLocationCoordinate2D(latitude: 37.765, longitude: -122.47),
            zoom: 11.6, bearing: 70, pitch: 62),
        // Low and from the south-west, looking across Twin Peaks at the deck.
        "side": CameraOptions(
            center: CLLocationCoordinate2D(latitude: 37.752, longitude: -122.447),
            zoom: 12.6, bearing: 35, pitch: 78),
    ]

    init() {
        // Launch arguments (`simctl launch … -mode volume -camera overview`)
        // set the initial state, so each check can be screenshotted unattended.
        let args = UserDefaults.standard
        if let mode = args.string(forKey: "mode").flatMap(Mode.init) { self.mode = mode }
        if let lighting = args.string(forKey: "lighting").flatMap(Lighting.init) { self.lighting = lighting }
        if args.object(forKey: "top") != nil { topM = args.float(forKey: "top") }
        if args.object(forKey: "budget") != nil { volumeBudget = args.integer(forKey: "budget") }
        cornerMarker = args.bool(forKey: "cornerMarker")
        alphaTest = args.bool(forKey: "alphaTest")

        let camera = Self.cameraPresets[args.string(forKey: "camera") ?? ""]
            ?? Self.cameraPresets["oblique"]!
        // Without a token the Mapbox basemap 401s, so fall back to a style with
        // no Mapbox-hosted sources. Terrain and fog checks still run against it.
        let token = Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String ?? ""
        mapView = MapView(
            frame: .zero, mapInitOptions: MapInitOptions(cameraOptions: camera, styleURI: nil))

        mapView.mapboxMap.onMapLoadingError.observe { [weak self] event in
            self?.lastError = "\(event.type): \(event.message)"
        }.store(in: &cancelables)

        // Time from handing GeoJSON to the SDK until it reports the data parsed.
        mapView.mapboxMap.onSourceDataLoaded.observe { [weak self] event in
            guard let self, event.sourceId == Self.volumeSource,
                  let dataId = event.dataId, let sent = self.volumeSentAt.removeValue(forKey: dataId)
            else { return }
            self.volumeReadyMs = (CACurrentMediaTime() - sent) * 1000
        }.store(in: &cancelables)

        mapView.mapboxMap.onRenderFrameFinished.observe { [weak self] _ in
            self?.countFrame()
        }.store(in: &cancelables)

        // Loaded explicitly, after the observers exist: an inline style passed
        // to MapInitOptions finishes loading inside MapView's initialiser, so
        // an onStyleLoaded observer attached afterwards never fires.
        let loaded: (Error?) -> Void = { [weak self] error in
            if let error { self?.lastError = "style: \(error)" } else { self?.installLayers() }
        }
        if token.isEmpty {
            mapView.mapboxMap.loadStyle(Self.offlineStyle, completion: loaded)
        } else {
            // `-style light|dark|monochrome`: which basemap white fog reads on.
            switch args.string(forKey: "style") {
            case "dark":
                mapView.mapboxMap.loadStyle(.dark, completion: loaded)
            case "monochrome":
                mapView.mapboxMap.loadStyle(.standard) { [weak self] error in
                    try? self?.mapView.mapboxMap.setStyleImportConfigProperty(
                        for: "basemap", config: "theme", value: "monochrome")
                    try? self?.mapView.mapboxMap.setStyleImportConfigProperty(
                        for: "basemap", config: "lightPreset", value: "dusk")
                    loaded(error)
                }
            default:
                mapView.mapboxMap.loadStyle(.light, completion: loaded)
            }
        }
    }

    // MARK: - Setup

    private func installLayers() {
        let map = mapView.mapboxMap!
        do {
            // Same Terrarium tiles the backend's DEM is resampled from.
            var dem = RasterDemSource(id: Self.terrainSource)
            dem.tiles = ["https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"]
            dem.tileSize = 256
            dem.maxzoom = 14
            dem.encoding = .terrarium
            try map.addSource(dem)

            // The web page's relief shading; neither basemap has any.
            var hillshade = HillshadeLayer(id: "hillshade", source: Self.terrainSource)
            hillshade.hillshadeExaggeration = .constant(0.45)
            hillshade.hillshadeShadowColor = .constant(StyleColor(UIColor(red: 0.353, green: 0.408, blue: 0.439, alpha: 1)))
            try map.addLayer(hillshade)

            var image = ImageSource(id: Self.fogSource)
            image.coordinates = Domain.imageCorners
            try map.addSource(image)

            var drape = RasterLayer(id: "fog-drape", source: Self.fogSource)
            drape.rasterOpacity = .constant(1)
            drape.rasterResampling = .constant(.linear)
            drape.rasterFadeDuration = .constant(0)
            // Standard's light presets shade every layer; fog is not lit
            // terrain, so it must not be darkened at dusk. No-op on classic styles.
            drape.rasterEmissiveStrength = .constant(1)
            try map.addLayer(drape)

            var volume = GeoJSONSource(id: Self.volumeSource)
            volume.data = .featureCollection(FeatureCollection(features: []))
            try map.addSource(volume)

            var extrusion = FillExtrusionLayer(id: "fog-volume", source: Self.volumeSource)
            extrusion.fillExtrusionHeight = .expression(Exp(.get) { "h" })
            extrusion.fillExtrusionBase = .constant(0)
            extrusion.fillExtrusionOpacity = .constant(0.62)
            extrusion.fillExtrusionVerticalGradient = .constant(false)
            try map.addLayer(extrusion)

            // Vector ground truth for the alignment check: the domain outline,
            // its NW corner, and summits the fog should part around. If the
            // image corners are right, the red raster square sits on the blue
            // circle and the holes in the drape sit on the orange ones.
            var reference = GeoJSONSource(id: "reference")
            reference.data = .featureCollection(Self.referenceFeatures)
            try map.addSource(reference)
            var outline = LineLayer(id: "reference-outline", source: "reference")
            outline.filter = Exp(.eq) { Exp(.geometryType); "LineString" }
            outline.lineColor = .constant(StyleColor(.systemBlue))
            outline.lineWidth = .constant(2)
            try map.addLayer(outline)
            var points = CircleLayer(id: "reference-points", source: "reference")
            points.filter = Exp(.eq) { Exp(.geometryType); "Point" }
            points.circleRadius = .constant(6)
            points.circleColor = .expression(Exp(.get) { "color" })
            points.circleStrokeColor = .constant(StyleColor(.black))
            points.circleStrokeWidth = .constant(1)
            try map.addLayer(points)

            styleReady = true
            styleStatus = "style loaded"
            applyReferenceVisibility()
            applyTerrain()
            applyLighting()
            applyExtrusionColor()
            applyMode()
            refreshFog()
            if UserDefaults.standard.bool(forKey: "orbit"), !orbiting { toggleOrbit() }
        } catch {
            lastError = "layer setup: \(error)"
        }
    }

    private static let referenceFeatures: FeatureCollection = {
        func point(_ lat: Double, _ lon: Double, _ color: String) -> Feature {
            var feature = Feature(geometry: .point(Point(CLLocationCoordinate2D(latitude: lat, longitude: lon))))
            feature.properties = ["color": .string(color)]
            return feature
        }
        let corners = Domain.imageCorners + [Domain.imageCorners[0]]
        let outline = Feature(geometry: .lineString(LineString(corners.map {
            CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0])
        })))
        return FeatureCollection(features: [
            outline,
            point(Domain.latMax, Domain.lonMin, "#1e6bff"),   // NW corner
            point(37.7544, -122.4477, "#ff8c00"),              // Twin Peaks, 281 m
            point(37.6879, -122.4343, "#ff8c00"),              // San Bruno Mountain, 400 m
            point(37.9235, -122.5965, "#ff8c00"),              // Mt Tamalpais, 784 m
        ])
    }()

    // MARK: - Checks

    func applyReferenceVisibility() {
        guard styleReady else { return }
        let visibility = cornerMarker ? "visible" : "none"
        record {
            try mapView.mapboxMap.setLayerProperty(for: "reference-outline", property: "visibility", value: visibility)
            try mapView.mapboxMap.setLayerProperty(for: "reference-points", property: "visibility", value: visibility)
        }
    }

    func applyTerrain() {
        guard styleReady else { return }
        var terrain = Terrain(sourceId: Self.terrainSource)
        terrain.exaggeration = .constant(exaggeration)
        record { try mapView.mapboxMap.setTerrain(terrain) }
    }

    func applyMode() {
        guard styleReady else { return }
        record {
            try mapView.mapboxMap.setLayerProperty(
                for: "fog-drape", property: "visibility",
                value: mode == .drape ? "visible" : "none")
            try mapView.mapboxMap.setLayerProperty(
                for: "fog-volume", property: "visibility",
                value: mode == .volume ? "visible" : "none")
        }
        refreshFog()
    }

    /// Density lives in lightness because MapLibre ignores alpha in
    /// fill-extrusion-color. The alpha test swaps in a near-transparent red:
    /// if the columns still render solid red, Mapbox ignores it too.
    func applyExtrusionColor() {
        guard styleReady else { return }
        let color: Value<StyleColor> = alphaTest
            ? .constant(StyleColor(UIColor(red: 1, green: 0.1, blue: 0.1, alpha: 0.08)))
            : .expression(Exp(.interpolate) {
                Exp(.linear)
                Exp(.get) { "f" }
                0.05; UIColor(red: 0.725, green: 0.776, blue: 0.804, alpha: 1)
                0.35; UIColor(red: 0.831, green: 0.871, blue: 0.890, alpha: 1)
                0.7; UIColor(red: 0.918, green: 0.945, blue: 0.957, alpha: 1)
                1.0; UIColor(red: 0.984, green: 0.992, blue: 0.996, alpha: 1)
            })
        record {
            try mapView.mapboxMap.updateLayer(withId: "fog-volume", type: FillExtrusionLayer.self) {
                $0.fillExtrusionColor = color
            }
        }
    }

    /// `flat` mirrors the web page's near-overhead viewport light; `3D` is
    /// Mapbox v11's ambient + directional pair.
    func applyLighting() {
        guard styleReady else { return }
        record {
            switch lighting {
            case .flat:
                var flat = FlatLight(id: "flat")
                flat.anchor = .constant(.viewport)
                flat.color = .constant(StyleColor(.white))
                flat.intensity = .constant(0.95)
                flat.position = .constant([1.15, 210, 12])
                try mapView.mapboxMap.setLights(flat)
            case .threeD:
                var ambient = AmbientLight(id: "ambient")
                ambient.color = .constant(StyleColor(.white))
                ambient.intensity = .constant(0.75)
                var sun = DirectionalLight(id: "sun")
                sun.color = .constant(StyleColor(.white))
                sun.intensity = .constant(0.35)
                sun.direction = .constant([210, 20])
                try mapView.mapboxMap.setLights(ambient: ambient, directional: sun)
            }
        }
    }

    /// Regenerates the synthetic field and pushes it to whichever layer is showing.
    func refreshFog() {
        guard styleReady else { return }
        let fog = SyntheticFog.field(elevation: elevation, topM: topM)
        switch mode {
        case .drape:
            let started = CACurrentMediaTime()
            let image = FogImage.render(fog, detail: 3, density: density, cornerMarker: cornerMarker)
            let rendered = CACurrentMediaTime()
            record { try mapView.mapboxMap.updateImageSource(withId: Self.fogSource, image: image) }
            imageRenderMs = (rendered - started) * 1000
            imageUpdateMs = (CACurrentMediaTime() - rendered) * 1000
        case .volume:
            let started = CACurrentMediaTime()
            let collection = FogVolume.build(
                fog: fog, elevation: elevation, topM: topM, budget: volumeBudget)
            volumeBuildMs = (CACurrentMediaTime() - started) * 1000
            volumeFeatures = collection.features.count
            volumeSequence += 1
            let dataId = String(volumeSequence)
            volumeSentAt[dataId] = CACurrentMediaTime()
            volumeReadyMs = nil
            mapView.mapboxMap.updateGeoJSONSource(
                withId: Self.volumeSource, geoJSON: .featureCollection(collection), dataId: dataId)
        }
    }

    /// Rotates the camera continuously so the FPS readout means something.
    func toggleOrbit() {
        orbiting.toggle()
        if orbiting {
            let link = CADisplayLink(target: OrbitTarget { [weak self] in self?.orbitStep() },
                                     selector: #selector(OrbitTarget.tick))
            link.add(to: .main, forMode: .common)
            orbitLink = link
        } else {
            orbitLink?.invalidate()
            orbitLink = nil
        }
    }

    // MARK: - Helpers

    private func orbitStep() {
        let bearing = mapView.mapboxMap.cameraState.bearing + 0.4
        mapView.mapboxMap.setCamera(to: CameraOptions(bearing: bearing))
    }

    private func countFrame() {
        frames += 1
        let now = CACurrentMediaTime()
        if now - fpsWindowStart >= 1 {
            fps = Double(frames) / (now - fpsWindowStart)
            frames = 0
            fpsWindowStart = now
        }
    }

    private func record(_ body: () throws -> Void) {
        do { try body() } catch { lastError = "\(error)" }
    }
}

/// CADisplayLink retains its target; this breaks the cycle with the controller.
private final class OrbitTarget {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func tick() { action() }
}
