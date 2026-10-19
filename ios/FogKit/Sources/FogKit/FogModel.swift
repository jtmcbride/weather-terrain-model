import Foundation

// Assembles the fog grid from terrain, a slab diagnosis, and observations.
// Port of backend/app/services/fog_model.py.

/// How far outside the domain a station may sit and still be seeded at the
/// nearest edge cell. Beyond this it is dropped rather than misattributed.
let stationClampMarginDeg = 0.15

/// One observation, already collapsed to the quantities the model needs.
public struct FogStationInput: Sendable, Equatable {
    public var source: String
    public var latitude: Double
    public var longitude: Double
    public var elevation: Double
    public var fogFraction: Double
    public var stationID: String?
    public var visibilityM: Double?
    public var relativeHumidity: Double?
    public var dewPointDepressionC: Double?
    public var cloudBaseM: Double?

    public init(
        source: String, latitude: Double, longitude: Double, elevation: Double,
        fogFraction: Double, stationID: String? = nil, visibilityM: Double? = nil,
        relativeHumidity: Double? = nil, dewPointDepressionC: Double? = nil, cloudBaseM: Double? = nil
    ) {
        self.source = source
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.fogFraction = fogFraction
        self.stationID = stationID
        self.visibilityM = visibilityM
        self.relativeHumidity = relativeHumidity
        self.dewPointDepressionC = dewPointDepressionC
        self.cloudBaseM = cloudBaseM
    }

    public var isFogged: Bool { fogFraction >= 0.5 }

    /// Whether marine air is over this station at all, fogged or not. A station
    /// under a stratus deck has good visibility and is still in marine air.
    public func marinePresence(slabTopM: Double) -> Double {
        var presence = fogFraction
        if let cloudBaseM, cloudBaseM < slabTopM { presence = max(presence, 1) }
        return min(max(presence, 0), 1)
    }
}

/// The tunable `fog_*` fields of backend/app/core/config.py.
public struct FogConfig: Sendable, Equatable {
    public var bounds = Bounds.sanFrancisco
    public var costBeta = 12.0
    public var costScaleM = 60.0
    public var blockBufferM = 25.0
    public var idwPower = 2.0
    public var fogVisibilityM = 1000.0
    public var maxVisibilityM = 24000.0
    public var fogDewPointDepressionC = 2.5
    public var edgeFeatherM = 30.0
    public var defaultFogTopM = 300.0
    /// `config.forecast_cache_ttl_seconds` / `metar_cache_ttl_seconds`. Data
    /// older than these was served stale, and the pipeline says so.
    public var forecastCacheTTLSeconds = 900.0
    public var metarCacheTTLSeconds = 300.0

    public init() {}
}

/// Per-render controls. Port of the model-facing fields of `FogGridRequest`.
public struct FogGridOptions: Sendable, Equatable {
    /// Off falls back to straight-line IDW, so fog walks through ridges.
    public var terrainRouting = true
    public var costBeta: Double
    public var costScaleM: Double
    public var blockBufferM: Double
    public var idwPower: Double
    public var maxVisibilityM: Double
    public var edgeFeatherM: Double

    public init(config: FogConfig = FogConfig()) {
        costBeta = config.costBeta
        costScaleM = config.costScaleM
        blockBufferM = config.blockBufferM
        idwPower = config.idwPower
        maxVisibilityM = config.maxVisibilityM
        edgeFeatherM = config.edgeFeatherM
    }
}

public struct FogGridResult: Sendable {
    public var fogFraction: Grid<Double>
    public var visibilityM: Grid<Double>
    public var surfaceState: Grid<SurfaceState>
    public var marineInfluence: Grid<Double>
    public var elevation: Grid<Double>
    public var usedStations: [FogStationInput]
    public var method: String
    public var warnings: [String]
}

/// The backend's shape-mismatch error has no equivalent: the grid size is
/// taken from the elevation grid itself, so the two cannot disagree.
public enum FogModelError: Error, Equatable, CustomStringConvertible {
    case noStations
    case noStationsInBounds

    public var description: String {
        switch self {
        case .noStations: "at least one station observation is required"
        case .noStationsInBounds: "no observations fall inside the requested bounds"
        }
    }
}

private func clampedCell(_ geometry: RasterGeometry, _ station: FogStationInput) -> Int? {
    if let index = geometry.cellIndex(latitude: station.latitude, longitude: station.longitude) {
        return index
    }
    let bounds = geometry.bounds
    let latitude = min(max(station.latitude, bounds.latMin), bounds.latMax)
    let longitude = min(max(station.longitude, bounds.lonMin), bounds.lonMax)
    if abs(latitude - station.latitude) > stationClampMarginDeg
        || abs(longitude - station.longitude) > stationClampMarginDeg {
        return nil
    }
    return geometry.cellIndex(latitude: latitude, longitude: longitude)
}

/// Interpolate marine influence, then cut it against the terrain.
///
/// The two steps are deliberately separate:
///
/// 1. *Horizontal* -- how much marine air reaches each cell, routed around
///    terrain standing above the inversion rather than straight through it.
/// 2. *Vertical* -- whether the ground at that cell lies inside the slab.
///
/// Multiplying them puts the fog edge on a hillside contour instead of a
/// blurred circle around the nearest station. There is no diffusion step, and
/// there should not be one: fog extent is a level set, not a spreading front.
///
/// Dijkstra runs once per station across all cores; call this off the main
/// actor.
public func buildFogGrid(
    bounds: Bounds,
    elevation: Grid<Double>,
    stations: [FogStationInput],
    slab: SlabDiagnosis,
    options: FogGridOptions = FogGridOptions()
) throws(FogModelError) -> FogGridResult {
    let geometry = RasterGeometry(bounds: bounds, gridX: elevation.width, gridY: elevation.height)
    guard !stations.isEmpty else { throw .noStations }
    var warnings: [String] = []

    var seeded: [FogStationInput] = []
    var seedCells: [Int] = []
    for station in stations {
        guard let index = clampedCell(geometry, station) else { continue }
        seeded.append(station)
        seedCells.append(index)
    }
    let dropped = stations.count - seeded.count
    if dropped > 0 {
        warnings.append("\(dropped) observation(s) fell outside the domain and were not used.")
    }
    guard !seeded.isEmpty else { throw .noStationsInBounds }

    let presence = seeded.map { $0.marinePresence(slabTopM: slab.topM) }
    if presence.max()! <= 0 {
        // A clear day: the field is empty for a different reason than "the fog
        // was blocked", and the slider looks broken unless the response says so.
        warnings.append(
            "No observation reports marine air anywhere in the domain, so the "
            + "fog field is empty regardless of the slab. This is the normal "
            + "clear-day answer, not a failure.")
    }

    var idw = InverseDistanceWeighting(cellCount: elevation.count, power: options.idwPower)
    let method: String
    if options.terrainRouting {
        let cell = geometry.cellSizeM
        let surface = CostSurface(
            elevation: elevation, cellDyM: cell.dy, cellDxM: cell.dx, fogTopM: slab.topM,
            beta: options.costBeta, scaleM: options.costScaleM, blockBufferM: options.blockBufferM)
        forEachInParallel(seeded.count) { surface.distances(from: seedCells[$0]) } consume: { i, distances in
            idw.add(distances: distances, value: presence[i])
        }
        method = "Terrain cost-distance IDW: marine influence is routed around ridges "
            + "standing above the diagnosed inversion, then cut vertically against "
            + "the DEM by the fog slab."
    } else {
        for (i, station) in seeded.enumerated() {
            idw.add(
                distances: geographicDistances(
                    geometry: geometry, latitude: station.latitude, longitude: station.longitude),
                value: presence[i])
        }
        method = "Geographic IDW baseline with no terrain routing: influence crosses "
            + "ridges unimpeded. Included for comparison."
    }

    let (influence, reachable) = idw.result()
    let blocked = reachable.lazy.filter { !$0 }.count
    if blocked > 0 {
        warnings.append("\(blocked) cell(s) are sealed off above the inversion and were set fog-free.")
    }

    let feather = options.edgeFeatherM
    var fog = [Double](repeating: 0, count: elevation.count)
    var visibility = [Double](repeating: 0, count: elevation.count)
    var states = [SurfaceState](repeating: .clear, count: elevation.count)
    for i in fog.indices {
        let ground = elevation.values[i]
        let occupancy = slabOccupancy(elevation: ground, baseM: slab.baseM, topM: slab.topM, featherM: feather)
        fog[i] = min(max(influence[i] * occupancy, 0), 1)
        visibility[i] = visibilityFromFogFraction(fog[i], maxVisibilityM: options.maxVisibilityM)
        states[i] = classifySurface(
            elevation: ground, fogFraction: fog[i], marineInfluence: influence[i],
            baseM: slab.baseM, topM: slab.topM, featherM: feather)
    }

    let shape = { (values: [Double]) in Grid(width: elevation.width, height: elevation.height, values: values) }
    return FogGridResult(
        fogFraction: shape(fog),
        visibilityM: shape(visibility),
        surfaceState: Grid(width: elevation.width, height: elevation.height, values: states),
        marineInfluence: shape(influence),
        elevation: elevation,
        usedStations: seeded,
        method: method,
        warnings: warnings + slab.warnings)
}
