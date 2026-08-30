// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Reticle",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ReticleCore", targets: ["ReticleCore"]),
        .executable(name: "reticle", targets: ["Reticle"]),
    ],
    dependencies: [
        // The transport, pairing, TLS and motion pipeline all come from AirPoint. This game
        // adds a handler and a scene; it reimplements none of that.
        .package(url: "https://github.com/brianlo06/airpoint.git", .upToNextMinor(from: "0.2.0")),
    ],
    targets: [
        // Game rules, deliberately free of SpriteKit and of the network, so they can be
        // tested without a window server or a phone.
        .target(
            name: "ReticleCore",
            dependencies: [.product(name: "RemoteKit", package: "airpoint")],
            path: "Sources/ReticleCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Reticle",
            dependencies: [
                "ReticleCore",
                .product(name: "RemoteKit", package: "airpoint"),
                .product(name: "RemoteServer", package: "airpoint"),
            ],
            path: "Sources/Reticle",
            resources: [.copy("Resources/web")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ReticleTests",
            dependencies: ["ReticleCore"],
            path: "Tests/ReticleTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
