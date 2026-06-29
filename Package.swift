// swift-tools-version: 6.2
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
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Voice",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // Sparkle.framework is embedded at Contents/Frameworks by scripts/build-app.sh;
            // this rpath lets the bundled executable find it at runtime.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
