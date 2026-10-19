import CoreGraphics
import Foundation
import FogKit

// The drape bitmap. Port of `prepareFogField` / `resampleField` /
// `fogImageDataUrl` in frontend/fog-map.html.
//
// Everything here is rendering, not model output. `fog_fraction` is an exact
// level set at the DEM's cell size; painted straight into pixels it is a flat,
// evenly opaque sheet with visible cell edges -- a data overlay, not weather.
// Two things fix that without touching the model:
//
// 1. the field is resampled with a Catmull-Rom kernel, so the fog line is a
//    curve rather than a staircase of DEM cells;
// 2. alpha is modulated by fractal noise weighted towards the thin edges of
//    the deck, which is where real stratus is ragged.
//
// Billow 0 turns (2) off and shows the level set exactly. Keep that escape
// hatch, and never push the billow into FogKit.
//
// One thing the web page does not do: rows are sampled at Web-Mercator
// spacing. A map image source is stretched linearly in Mercator, while the
// grid is linear in latitude, which misplaces rows by up to 49 m north-south
// over the SF domain -- half a cell at 560 x 612.

/// The resampled field, cached so that density and billow changes only repaint.
public struct FogField: Sendable {
    public let width: Int
    public let height: Int
    public let values: [Float]
}

public enum FogTexture {
    /// The largest bitmap edge, as on the web page.
    public static let maxEdge = 2048

    /// Resample `fog` to `detail` pixels per cell, with Mercator-spaced rows.
    public static func prepare(_ fog: Grid<Double>, bounds: Bounds, detail: Int) -> FogField {
        let gx = fog.width, gy = fog.height
        let width = min(maxEdge, max(gx, gx * detail))
        let height = min(maxEdge, max(gy, gy * detail))
        let source = fog.values.map(Float.init)

        // Pass 1: horizontal, `gy` rows of `width`. Longitude is linear in
        // Mercator, so columns need no correction.
        var rows = [Float](repeating: 0, count: gy * width)
        let scaleX = Float(gx - 1) / Float(max(width - 1, 1))
        for row in 0..<gy {
            let base = row * gx
            for x in 0..<width {
                let sx = Float(x) * scaleX
                let x1 = Int(sx)
                rows[row * width + x] = catmullRom(
                    source[base + clamp(x1 - 1, gx)], source[base + clamp(x1, gx)],
                    source[base + clamp(x1 + 1, gx)], source[base + clamp(x1 + 2, gx)],
                    sx - Float(x1))
            }
        }

        // Pass 2: vertical, at the grid row each Mercator-spaced pixel row
        // actually falls on.
        var out = [Float](repeating: 0, count: width * height)
        let sourceRows = mercatorSourceRows(height: height, gridY: gy, bounds: bounds)
        for y in 0..<height {
            let sy = sourceRows[y]
            let y1 = Int(sy.rounded(.down))
            let t = Float(sy - Double(y1))
            let r0 = clamp(y1 - 1, gy) * width, r1 = clamp(y1, gy) * width
            let r2 = clamp(y1 + 1, gy) * width, r3 = clamp(y1 + 2, gy) * width
            for x in 0..<width {
                // Catmull-Rom overshoots at a hard edge, and a fog fraction is
                // a fraction: clamp rather than let the ringing become a halo.
                let value = catmullRom(rows[r0 + x], rows[r1 + x], rows[r2 + x], rows[r3 + x], t)
                out[y * width + x] = min(max(value, 0), 1)
            }
        }
        return FogField(width: width, height: height, values: out)
    }

    /// Fractional grid row for each bitmap row. Pixel row 0 is the grid's
    /// north row and the last pixel row its south row; between them, pixel rows
    /// are evenly spaced in Mercator y, which is how the map will draw them.
    static func mercatorSourceRows(height: Int, gridY: Int, bounds: Bounds) -> [Double] {
        let north = mercatorY(bounds.latMax), south = mercatorY(bounds.latMin)
        let span = bounds.latMax - bounds.latMin
        return (0..<height).map { y in
            guard height > 1 else { return 0 }
            let mercator = north + (south - north) * Double(y) / Double(height - 1)
            return (bounds.latMax - latitude(mercatorY: mercator)) / span * Double(gridY - 1)
        }
    }

    static func mercatorY(_ latitude: Double) -> Double {
        log(tan(.pi / 4 + latitude * .pi / 360))
    }

    static func latitude(mercatorY y: Double) -> Double {
        (2 * atan(exp(y)) - .pi / 2) * 180 / .pi
    }

    /// Paint the field: near-white, alpha from fog fraction, billowed at the
    /// deck's margins. Density belongs in alpha, not hue -- a colour ramp would
    /// read as a data overlay.
    public static func render(_ field: FogField, density: Double, billow: Double) -> CGImage {
        let width = field.width, height = field.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // Two noise scales, both in pixel space so the billow size is fixed on
        // the ground rather than growing with the detail setting: a slow one
        // for the shape of the deck, a fast one for its ragged edge.
        let size = Double(FogNoise.size)
        let slow = size * 1.6 / Double(width)
        let fast = size * 5.5 / Double(width)

        for y in 0..<height {
            let slowY = Double(y) * slow
            let fastY = Double(y) * fast + 211
            for x in 0..<width {
                let i = y * width + x
                let f = Double(field.values[i])
                var alpha = f
                if billow > 0 && f > 0 {
                    let n = 0.68 * Double(FogNoise.at(Double(x) * slow, slowY))
                        + 0.32 * Double(FogNoise.at(Double(x) * fast + 97, fastY))
                    // Strongest where the deck is thin, vanishing in the dense
                    // core: stratus is uniform in the middle, shredded at the edge.
                    let edge = 4 * f * (1 - f)
                    alpha *= 1 + billow * edge * (n - 0.5) * 2.2
                }
                // A gentle gamma thins the weak tail without touching the core.
                alpha = pow(min(max(alpha, 0), 1), 1.25) * density
                alpha = min(alpha, 1)
                // Near-white, cooling very slightly as the fog thickens.
                // Premultiplied, as CGImage's premultipliedLast expects.
                let shade = 1 - 0.06 * f
                pixels[i * 4] = UInt8(252 * shade * alpha)
                pixels[i * 4 + 1] = UInt8(253 * shade * alpha)
                pixels[i * 4 + 2] = UInt8(255 * shade * alpha)
                pixels[i * 4 + 3] = UInt8(255 * alpha)
            }
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    @inline(__always)
    static func catmullRom(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
        let t2 = t * t, t3 = t2 * t
        let linear = 2 * p1 + (p2 - p0) * t
        let quadratic = (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
        let cubic = (3 * p1 - 3 * p2 + p3 - p0) * t3
        return 0.5 * (linear + quadratic + cubic)
    }

    @inline(__always)
    private static func clamp(_ index: Int, _ count: Int) -> Int { min(max(index, 0), count - 1) }
}
