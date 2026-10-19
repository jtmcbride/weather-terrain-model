import Foundation

/// The fractal billow field. Port of `buildNoiseTexture` / `noiseAt` in
/// frontend/fog-map.html, bit-compatible with its 32-bit hash so the deck
/// billows the same way on the phone as on the page.
///
/// Tileable, built once, sampled at any scale with a wrap.
public enum FogNoise {
    public static let size = 512
    static let octaves = 5

    public static let texture: [Float] = {
        var texture = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            let v = Double(y) / Double(size)
            for x in 0..<size {
                let u = Double(x) / Double(size)
                var sum = 0.0, amplitude = 0.5, total = 0.0, period = 4
                for octave in 0..<octaves {
                    sum += amplitude * valueNoise(u, v, period: period, seed: UInt32(octave + 1))
                    total += amplitude
                    amplitude *= 0.5
                    period *= 2
                }
                texture[y * size + x] = Float(sum / total)
            }
        }
        return texture
    }()

    /// Wrapped lookup; coordinates are in texels and truncate like `x | 0`.
    @inline(__always)
    public static func at(_ x: Double, _ y: Double) -> Float {
        let xi = ((Int(x) % size) + size) % size
        let yi = ((Int(y) % size) + size) % size
        return texture[yi * size + xi]
    }

    /// JavaScript's `Math.imul` arithmetic is multiplication mod 2^32, so the
    /// whole hash is plain wrapping UInt32 arithmetic.
    static func hash(_ x: Int, _ y: Int, _ seed: UInt32) -> Double {
        var h = UInt32(truncatingIfNeeded: x) &* 374_761_393
            &+ UInt32(truncatingIfNeeded: y) &* 668_265_263
            &+ seed &* 1_442_695_041
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Double(h ^ (h >> 16)) / 4_294_967_295
    }

    static func valueNoise(_ u: Double, _ v: Double, period: Int, seed: UInt32) -> Double {
        func fade(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        func wrap(_ n: Int) -> Int { ((n % period) + period) % period }
        let x = u * Double(period), y = v * Double(period)
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = fade(x - Double(x0)), fy = fade(y - Double(y0))
        let xa = wrap(x0), xb = wrap(x0 + 1), ya = wrap(y0), yb = wrap(y0 + 1)
        let n00 = hash(xa, ya, seed), n10 = hash(xb, ya, seed)
        let n01 = hash(xa, yb, seed), n11 = hash(xb, yb, seed)
        return (n00 * (1 - fx) + n10 * fx) * (1 - fy) + (n01 * (1 - fx) + n11 * fx) * fy
    }
}
