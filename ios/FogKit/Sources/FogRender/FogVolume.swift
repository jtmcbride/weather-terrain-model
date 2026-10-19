import Foundation
import FogKit

// Volume mode: one extruded column per block, from the ground up towards the
// inversion. Port of `buildVolume` in frontend/fog-map.html, minus the map
// types, so the app turns blocks into features.

public struct VolumeBlock: Sendable, Equatable {
    public var north: Double
    public var south: Double
    public var west: Double
    public var east: Double
    /// The densest fog in the block. Drives lightness, never alpha: map
    /// extrusions ignore the alpha channel of their colour.
    public var fog: Double
    /// Metres above the terrain, which is how map extrusions are measured.
    public var height: Double
}

public enum FogVolume {
    /// Well above the ~5,000 that made the deck a grid of boxes, and below
    /// the ~45,000 that took the map ~840 ms to ingest (see ios/Spike).
    public static let defaultBudget = 12_000

    public static func blocks(
        fog: Grid<Double>, elevation: Grid<Double>, bounds: Bounds, topM: Double,
        budget: Int = defaultBudget, billow: Double
    ) -> [VolumeBlock] {
        let gx = fog.width, gy = fog.height
        let step = max(1, Int((Double(gx * gy) / Double(budget)).squareRoot().rounded()))
        let latSpan = bounds.latMax - bounds.latMin
        let lonSpan = bounds.lonMax - bounds.lonMin
        // Deliberately low frequency: one billow spans about ten blocks.
        // Sampled per block, neighbouring roofs differ sharply in height and
        // expose thousands of dark side walls, which reads as dirt.
        let noiseScale = Double(FogNoise.size) / Double(max(gx, gy)) / 7
        var blocks: [VolumeBlock] = []

        for row in stride(from: 0, through: gy - step, by: step) {
            for col in stride(from: 0, through: gx - step, by: step) {
                // Densest fog and highest ground in the block, so a narrow fog
                // tongue or a thin ridge survives coarsening. The mean ground
                // matters too: the map lifts an extrusion by sampling terrain
                // at its centroid, so height is measured from about there.
                var maxFog = 0.0, sumFog = 0.0, maxElevation = -Double.infinity, sumElevation = 0.0
                for r in row..<(row + step) {
                    for c in col..<(col + step) {
                        let f = fog[r, c], e = elevation[r, c]
                        maxFog = max(maxFog, f); sumFog += f
                        maxElevation = max(maxElevation, e); sumElevation += e
                    }
                }
                // Low enough to keep the wisps that stop a volume reading as a
                // solid table.
                if maxFog < 0.05 { continue }
                // A crest reaching the inversion is a ridge poking through the
                // deck, not fog.
                if maxElevation >= topM { continue }
                let count = Double(step * step)
                let ceiling = topM - sumElevation / count
                if ceiling <= 5 { continue }

                // Thin fog does not reach the inversion, so the deck tapers
                // into its edge instead of ending in a wall of full-height
                // boxes; and the roof billows instead of being a plane.
                let lump = billow > 0
                    ? 1 + billow * 0.16 * (Double(FogNoise.at(Double(col) * noiseScale, Double(row) * noiseScale)) - 0.5) * 2
                    : 1
                let height = ceiling * (0.42 + 0.58 * sumFog / count) * lump
                if height <= 4 { continue }

                blocks.append(VolumeBlock(
                    north: bounds.latMax - Double(row) / Double(gy - 1) * latSpan,
                    south: bounds.latMax - Double(row + step) / Double(gy - 1) * latSpan,
                    west: bounds.lonMin + Double(col) / Double(gx - 1) * lonSpan,
                    east: bounds.lonMin + Double(col + step) / Double(gx - 1) * lonSpan,
                    fog: maxFog, height: height))
            }
        }
        return blocks
    }
}
