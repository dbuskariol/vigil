// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Vigil",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "vigil", targets: ["vigil"]),
        .executable(name: "VigilMenuBar", targets: ["VigilMenuBar"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMajor(from: "2.9.1"))
    ],
    targets: [
        .target(name: "VigilIdentifiers"),
        .target(name: "KeyboardBacklightBridge"),
        .executableTarget(
            name: "vigil",
            dependencies: ["KeyboardBacklightBridge", "VigilIdentifiers"]
        ),
        .executableTarget(
            name: "VigilMenuBar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "VigilIdentifiers"
            ]
        )
    ]
)
