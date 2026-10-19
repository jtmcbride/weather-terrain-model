import Foundation

/// A geographic rectangle. Port of `schemas.Bounds`.
public struct Bounds: Sendable, Equatable {
    public var latMin: Double
    public var latMax: Double
    public var lonMin: Double
    public var lonMax: Double

    public init(latMin: Double, latMax: Double, lonMin: Double, lonMax: Double) {
        self.latMin = latMin
        self.latMax = latMax
        self.lonMin = lonMin
        self.lonMax = lonMax
    }

    /// The San Francisco fog domain, `config.fog_bounds_*`.
    public static let sanFrancisco = Bounds(
        latMin: 37.44, latMax: 37.95, lonMin: -122.65, lonMax: -122.15)
}

/// A row-major raster. **Row 0 is the north edge** (`lat_max`), matching
/// `providers/dem.raster_coordinates` and every other part of the fog path.
public struct Grid<Element: Sendable>: Sendable {
    public let width: Int
    public let height: Int
    public var values: [Element]

    public init(width: Int, height: Int, values: [Element]) {
        precondition(values.count == width * height, "grid values do not match \(width)x\(height)")
        self.width = width
        self.height = height
        self.values = values
    }

    public init(width: Int, height: Int, repeating value: Element) {
        self.init(width: width, height: height, values: Array(repeating: value, count: width * height))
    }

    public var count: Int { values.count }

    public subscript(row: Int, col: Int) -> Element {
        get { values[row * width + col] }
        set { values[row * width + col] = newValue }
    }

    public func map<T>(_ transform: (Element) throws -> T) rethrows -> Grid<T> {
        Grid<T>(width: width, height: height, values: try values.map(transform))
    }
}

public enum ElevationGridError: Error, Equatable {
    case sizeMismatch(expectedBytes: Int, actualBytes: Int)
}

extension Grid where Element == Double {
    /// Reads a raw little-endian float32 grid, north-first, as written by
    /// `numpy.ndarray.astype("<f4").tofile` from the backend's DEM cache.
    public static func float32(contentsOf url: URL, width: Int, height: Int) throws -> Grid<Double> {
        let data = try Data(contentsOf: url)
        let expected = width * height * MemoryLayout<Float32>.size
        guard data.count == expected else {
            throw ElevationGridError.sizeMismatch(expectedBytes: expected, actualBytes: data.count)
        }
        let values = data.withUnsafeBytes { raw in
            (0..<(width * height)).map {
                Double(Float32(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))))
            }
        }
        return Grid(width: width, height: height, values: values)
    }
}

/// Where grid cells sit on the ground. Port of `dem.raster_coordinates`,
/// `dem.cell_size_m` and `cost_distance.cell_index`.
public struct RasterGeometry: Sendable, Equatable {
    public let bounds: Bounds
    public let gridX: Int
    public let gridY: Int

    public init(bounds: Bounds, gridX: Int, gridY: Int) {
        self.bounds = bounds
        self.gridX = gridX
        self.gridY = gridY
    }

    /// Latitude of a row's cell centres; row 0 is `latMax`.
    public func latitude(row: Int) -> Double {
        linspace(bounds.latMax, bounds.latMin, count: gridY, index: row)
    }

    public func longitude(col: Int) -> Double {
        linspace(bounds.lonMin, bounds.lonMax, count: gridX, index: col)
    }

    /// Approximate north-south and east-west cell size in metres.
    public var cellSizeM: (dy: Double, dx: Double) {
        let meanLat = (bounds.latMin + bounds.latMax) / 2 * .pi / 180
        let dy = (bounds.latMax - bounds.latMin) * 111_320.0 / Double(max(gridY - 1, 1))
        let dx = (bounds.lonMax - bounds.lonMin) * 111_320.0 * cos(meanLat) / Double(max(gridX - 1, 1))
        return (dy, dx)
    }

    /// Flat index of the cell containing a point, or nil if outside.
    public func cellIndex(latitude: Double, longitude: Double) -> Int? {
        guard (bounds.latMin...bounds.latMax).contains(latitude),
              (bounds.lonMin...bounds.lonMax).contains(longitude) else { return nil }
        let latSpan = bounds.latMax - bounds.latMin
        let lonSpan = bounds.lonMax - bounds.lonMin
        guard latSpan > 0, lonSpan > 0 else { return nil }
        // Python's round() is banker's rounding; match it so a point exactly
        // between two cells lands where the backend puts it.
        let row = Int(((bounds.latMax - latitude) / latSpan * Double(gridY - 1))
            .rounded(.toNearestOrEven))
        let col = Int(((longitude - bounds.lonMin) / lonSpan * Double(gridX - 1))
            .rounded(.toNearestOrEven))
        return min(max(row, 0), gridY - 1) * gridX + min(max(col, 0), gridX - 1)
    }

    /// numpy.linspace's formula, so coordinates match the backend bit for bit.
    private func linspace(_ start: Double, _ stop: Double, count: Int, index: Int) -> Double {
        guard count > 1 else { return start }
        if index == count - 1 { return stop }
        let step = (stop - start) / Double(count - 1)
        return start + Double(index) * step
    }
}
