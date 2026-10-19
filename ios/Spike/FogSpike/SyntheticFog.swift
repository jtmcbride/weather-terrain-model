import CoreGraphics
import Foundation

/// The SF fog domain, matching `config.fog_bounds_*`.
enum Domain {
    static let latMin = 37.44
    static let latMax = 37.95
    static let lonMin = -122.65
    static let lonMax = -122.15

    /// Image-source corners, north-first: TL, TR, BR, BL as [lon, lat].
    static let imageCorners: [[Double]] = [
        [lonMin, latMax], [lonMax, latMax], [lonMax, latMin], [lonMin, latMin],
    ]
}

/// A row-major grid, row 0 = north (the fog path's convention).
struct Grid {
    let width: Int
    let height: Int
    var values: [Float]

    subscript(row: Int, col: Int) -> Float { values[row * width + col] }
}

enum Elevation {
    /// Loads the raw Float32 grid written by `export_elevation.py`.
    static func load(width: Int, height: Int) -> Grid {
        guard
            let url = Bundle.main.url(
                forResource: "elevation-\(width)x\(height)", withExtension: "f32"),
            let data = try? Data(contentsOf: url),
            data.count == width * height * MemoryLayout<Float>.size
        else {
            fatalError("missing elevation-\(width)x\(height).f32; run export_elevation.py")
        }
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return Grid(width: width, height: height, values: values)
    }
}

/// A stand-in for model output, for exercising the renderer only.
///
/// This is the vertical cut alone -- a feathered level set of the ground
/// against the fog top -- times a crude west-to-east marine fade. It has the
/// property the renderer must preserve (the edge is a hillside contour) and
/// none of the physics: no routing, no slab diagnosis. Phase 1 replaces it.
enum SyntheticFog {
    static func field(elevation: Grid, topM: Float, featherM: Float = 30) -> Grid {
        var out = [Float](repeating: 0, count: elevation.values.count)
        let lonSpan = Domain.lonMax - Domain.lonMin
        for row in 0..<elevation.height {
            for col in 0..<elevation.width {
                let lon = Domain.lonMin + Double(col) / Double(elevation.width - 1) * lonSpan
                let marine = Float(min(max((-122.30 - lon) / 0.12, 0), 1))
                let e = elevation[row, col]
                let occupancy = smoothstep(topM + featherM, topM - featherM, e)
                out[row * elevation.width + col] = marine * occupancy
            }
        }
        return Grid(width: elevation.width, height: elevation.height, values: out)
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
