import FogKit
import Foundation

/// The grid sizes the app offers. Keep in step with `PRESETS` in
/// backend/scripts/export_elevation_grids.py, which writes the bundled files.
enum GridPreset: Int, CaseIterable, Identifiable {
    case coarse, standard, fine, finer, finest

    var id: Int { rawValue }

    var size: (x: Int, y: Int) {
        switch self {
        case .coarse: (160, 176)
        case .standard: (256, 280)
        case .fine: (340, 372)
        case .finer: (420, 420)
        case .finest: (560, 612)
        }
    }

    var label: String { "\(size.x) × \(size.y)" }

    /// The same derived DEM grid the backend reads, north-first. Terrain is
    /// static, so it ships with the app; elevation never touches the network.
    func elevation() throws -> Grid<Double> {
        guard let url = Bundle.main.url(forResource: "sf-\(size.x)x\(size.y)", withExtension: "f32") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Grid<Double>.float32(contentsOf: url, width: size.x, height: size.y)
    }
}
