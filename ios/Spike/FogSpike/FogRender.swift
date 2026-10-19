import CoreGraphics
import MapboxMaps
import UIKit

/// Drape: the fog field as a bitmap, upsampled to roughly the size the real
/// page paints (detail 3x), so update costs measured here are representative.
/// Bilinear only -- the Catmull-Rom resample and billow are phase 3.
enum FogImage {
    static func render(_ fog: Grid, detail: Int, density: Float, cornerMarker: Bool) -> UIImage {
        let width = fog.width * detail
        let height = fog.height * detail
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let sx = Float(fog.width - 1) / Float(width - 1)
        let sy = Float(fog.height - 1) / Float(height - 1)

        for y in 0..<height {
            let gy = Float(y) * sy
            let r0 = min(Int(gy), fog.height - 2)
            let ty = gy - Float(r0)
            for x in 0..<width {
                let gx = Float(x) * sx
                let c0 = min(Int(gx), fog.width - 2)
                let tx = gx - Float(c0)
                let top = fog[r0, c0] * (1 - tx) + fog[r0, c0 + 1] * tx
                let bottom = fog[r0 + 1, c0] * (1 - tx) + fog[r0 + 1, c0 + 1] * tx
                let f = top * (1 - ty) + bottom * ty

                let alpha = min(pow(max(f, 0), 1.25) * density, 1)
                let shade = 1 - 0.06 * f
                // Premultiplied, as CGImage's premultipliedLast expects.
                let i = (y * width + x) * 4
                pixels[i] = UInt8(252 * shade * alpha)
                pixels[i + 1] = UInt8(253 * shade * alpha)
                pixels[i + 2] = UInt8(255 * shade * alpha)
                pixels[i + 3] = UInt8(255 * alpha)
            }
        }

        if cornerMarker {
            // Opaque red in the image's top-left. If the corner order is right
            // it lands at the domain's north-west corner, off Point Reyes.
            let size = width / 12
            for y in 0..<size {
                for x in 0..<size {
                    let i = (y * width + x) * 4
                    pixels[i] = 255; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 255
                }
            }
        }

        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
        return UIImage(cgImage: image)
    }
}

/// Volume: a port of `buildVolume` in fog-map.html, minus the billow lump.
enum FogVolume {
    static func build(fog: Grid, elevation: Grid, topM: Float, budget: Int) -> FeatureCollection {
        let gx = fog.width, gy = fog.height
        let step = max(1, Int((Double(gx * gy) / Double(budget)).squareRoot().rounded()))
        let latSpan = Domain.latMax - Domain.latMin
        let lonSpan = Domain.lonMax - Domain.lonMin
        var features: [Feature] = []

        var row = 0
        while row + step <= gy {
            var col = 0
            while col + step <= gx {
                defer { col += step }
                // Densest fog and highest ground in the block, so thin ridges
                // and fog tongues survive coarsening.
                var maxFog: Float = 0, sumFog: Float = 0
                var maxElev = -Float.infinity, sumElev: Float = 0
                for r in row..<(row + step) {
                    for c in col..<(col + step) {
                        let f = fog[r, c], e = elevation[r, c]
                        maxFog = max(maxFog, f); sumFog += f
                        maxElev = max(maxElev, e); sumElev += e
                    }
                }
                let count = Float(step * step)
                if maxFog < 0.05 || maxElev >= topM { continue }
                let ceiling = topM - sumElev / count
                if ceiling <= 5 { continue }
                let height = ceiling * (0.42 + 0.58 * sumFog / count)
                if height <= 4 { continue }

                let north = Domain.latMax - Double(row) / Double(gy - 1) * latSpan
                let south = Domain.latMax - Double(row + step) / Double(gy - 1) * latSpan
                let west = Domain.lonMin + Double(col) / Double(gx - 1) * lonSpan
                let east = Domain.lonMin + Double(col + step) / Double(gx - 1) * lonSpan
                var feature = Feature(geometry: .polygon(Polygon([[
                    CLLocationCoordinate2D(latitude: north, longitude: west),
                    CLLocationCoordinate2D(latitude: north, longitude: east),
                    CLLocationCoordinate2D(latitude: south, longitude: east),
                    CLLocationCoordinate2D(latitude: south, longitude: west),
                    CLLocationCoordinate2D(latitude: north, longitude: west),
                ]])))
                feature.properties = ["f": .number(Double(maxFog)), "h": .number(Double(height))]
                features.append(feature)
            }
            row += step
        }
        return FeatureCollection(features: features)
    }
}
