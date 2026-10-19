// swift-tools-version: 6.0
import PackageDescription

// FogKit: the fog model ported from backend/app, plus the live data layer.
// FogRender: turning a fog grid into pixels and extrusions -- rendering, not
// model output, kept apart so it can never leak into the physics.
// macOS is a platform only so `swift test` runs on the host without a simulator.
let alwaysOptimised: [SwiftSetting] = [.unsafeFlags(["-O"], .when(configuration: .debug))]

let package = Package(
    name: "FogKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FogKit", targets: ["FogKit"]),
        .library(name: "FogRender", targets: ["FogRender"]),
    ],
    targets: [
        // Always optimised. Unoptimised Swift runs the per-station Dijkstra
        // ~90x slower (9 s instead of 0.1 s per grid in a Debug app build),
        // which makes the app unusable while debugging anything else.
        .target(name: "FogKit", swiftSettings: alwaysOptimised),
        .target(name: "FogRender", dependencies: ["FogKit"], swiftSettings: alwaysOptimised),
        .testTarget(
            name: "FogKitTests",
            dependencies: ["FogKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "FogRenderTests", dependencies: ["FogRender"]),
    ]
)
