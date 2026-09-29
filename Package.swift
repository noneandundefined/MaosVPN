// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "MaosVPN",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .executable(name: "MaosVPN", targets: ["MaosVPN"])
    ],
    targets: [
        .target(
            name: "MaosVPN",
            dependencies: ["MaosVPNCore"],
            path: "Sources/MaosVPN"
        ),
        .target(
            name: "MaosVPNCore",
            path: "Sources/MaosVPNCore"
        ),
        .testTarget(
            name: "MaosVPNTests",
            dependencies: ["MaosVPNCore"],
            path: "Tests/MaosVPNTests"
        )
    ]
)
