// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Voice",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "voice", targets: ["Voice"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.9.4"),
    ],
    targets: [
        .executableTarget(
            name: "Voice",
            dependencies: [
                "KeyboardShortcuts",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
