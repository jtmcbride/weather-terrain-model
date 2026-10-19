import Foundation
@testable import FogKit

// Synthetic terrain reproducing the San Francisco blocking geometry. Port of
// backend/tests/terrain_fixtures.py: a north-south ridge with a sea-level gap
// at its northern end standing in for the Golden Gate. Row 0 is north.

/// Roughly the real domain, so cell sizes come out near 100 m.
let peninsulaBounds = Bounds.sanFrancisco

let ridgeColumns = 36..<45
let gapRows = 4..<11

/// A ridge with one gap at its northern end.
func peninsula(
    rows: Int = 60, cols: Int = 80, crestM: Double = 300, lowlandM: Double = 10, gapM: Double = 15
) -> Grid<Double> {
    // A smooth hump, so cost varies across the ridge rather than jumping.
    let centre = Double(ridgeColumns.lowerBound + ridgeColumns.upperBound - 1) / 2
    let halfWidth = Double(ridgeColumns.count) / 2
    var grid = Grid(width: cols, height: rows, repeating: lowlandM)
    for row in 0..<rows {
        for col in 0..<cols {
            let offset = (Double(col) - centre) / halfWidth
            let profile = min(max(1 - offset * offset, 0), 1)
            var elevation = lowlandM + profile * (crestM - lowlandM)
            if gapRows.contains(row) { elevation = min(elevation, gapM) }
            grid[row, col] = elevation
        }
    }
    return grid
}

/// A single cone, for checking that a fog edge traces an elevation contour.
func conicalHill(rows: Int = 61, cols: Int = 61, summitM: Double = 400) -> Grid<Double> {
    func radius(_ row: Int, _ col: Int) -> Double {
        hypot(Double(row) - Double(rows - 1) / 2, Double(col) - Double(cols - 1) / 2)
    }
    let maxRadius = radius(0, 0)
    var grid = Grid(width: cols, height: rows, repeating: 0.0)
    for row in 0..<rows {
        for col in 0..<cols {
            grid[row, col] = summitM * min(max(1 - radius(row, col) / maxRadius, 0), 1)
        }
    }
    return grid
}
