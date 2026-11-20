// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HistqCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HistqCore", targets: ["HistqCore"]),
    ],
    dependencies: [
        // swift-markdown 0.9.0, pinned by commit.
        .package(url: "https://github.com/swiftlang/swift-markdown", revision: "25cb61d3482054b09ae76ca4f281b1bfe7fe5a43"),
        // swift-cmark 0.9.0 (swift-markdown's parser), pinned by commit: its C API measures a document's depth first.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", revision: "08ddb528923cc1a6527e02b7a1aee9e516ca749a"),
    ],
    targets: [
        .target(
            name: "HistqCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "HistqCoreTests", dependencies: ["HistqCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
