// swift-tools-version: 6.2
import PackageDescription

// NibUI is the ONLY package allowed to import AppKit or SwiftUI.
// Default isolation is MainActor here — this is a single-threaded UI program and the
// things that genuinely leave main (networking, parsing, file I/O) all live in the
// packages below, which are `nonisolated` by default.
let package = Package(
    name: "NibUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NibUI", targets: ["NibUI"])
    ],
    dependencies: [
        .package(path: "../NibCore"),
        .package(path: "../NibHTTP"),
        .package(path: "../NibStore"),
        .package(path: "../NibInterchange"),
        .package(path: "../NibTestSupport"),
    ],
    targets: [
        .target(
            name: "NibUI",
            dependencies: [
                .product(name: "NibCore", package: "NibCore"),
                .product(name: "NibHTTP", package: "NibHTTP"),
                .product(name: "NibStore", package: "NibStore"),
                .product(name: "NibInterchange", package: "NibInterchange"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "NibUITests",
            dependencies: [
                "NibUI",
                .product(name: "NibTestSupport", package: "NibTestSupport"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
    ]
)
