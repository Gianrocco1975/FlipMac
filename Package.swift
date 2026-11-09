// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FlipMac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FlipCore", targets: ["FlipCore"]),
        .executable(name: "flip", targets: ["flip"]),
        .executable(name: "FlipApp", targets: ["FlipApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6")
    ],
    targets: [
        .target(
            name: "FlipCore",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        .executableTarget(
            name: "flip",
            dependencies: ["FlipCore"]
        ),
        .executableTarget(
            name: "FlipApp",
            dependencies: ["FlipCore"]
        )
    ]
)
