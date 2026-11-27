// swift-tools-version: 6.0
// The Mac side of the cross-OS fixtures: writes HistqCore's state formats for the Windows tests and reads back what
// the Windows port writes (see windows/README.md, "Cross-platform fixtures"). It reads Packages/HistqCore by path and
// never edits it.
import PackageDescription

let package = Package(
    name: "FixtureBridge",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "fixture-bridge", targets: ["FixtureBridge"]),
    ],
    dependencies: [
        .package(path: "../../../Packages/HistqCore"),
    ],
    targets: [
        .executableTarget(
            name: "FixtureBridge",
            dependencies: [.product(name: "HistqCore", package: "HistqCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
