// swift-tools-version: 6.0
import PackageDescription

// Command Line Tools ship TestingMacros outside the default plugin directory.
// Load it explicitly so `swift test` works without Xcode.
let testingPlugin = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

let package = Package(
    name: "Nightdeck",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NightdeckCore", targets: ["NightdeckCore"]),
        .executable(name: "Nightdeck", targets: ["Nightdeck"]),
    ],
    targets: [
        .target(
            name: "NightdeckCore",
            path: "Sources/NightdeckCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Nightdeck",
            dependencies: ["NightdeckCore"],
            path: "Sources/Nightdeck",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NightdeckTests",
            dependencies: ["NightdeckCore", "Nightdeck"],
            path: "Tests/NightdeckTests",
            exclude: ["Fixtures"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-load-plugin-library", testingPlugin]),
            ]
        ),
    ]
)
