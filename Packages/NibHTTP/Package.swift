// swift-tools-version: 6.2
import PackageDescription

// NibHTTP is the URLSession engine. Foundation only — no AppKit, no SwiftUI.
//
// INVARIANT: NibHTTP never sees `{{vars}}`. Interpolation happens in NibCore and
// the engine receives a fully-resolved SendPlan. That separation is what makes
// the engine trivially testable against a localhost echo server.
let package = Package(
    name: "NibHTTP",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NibHTTP", targets: ["NibHTTP"])
    ],
    dependencies: [
        .package(path: "../NibCore"),
        .package(path: "../NibTestSupport"),
    ],
    targets: [
        .target(
            name: "NibHTTP",
            dependencies: [.product(name: "NibCore", package: "NibCore")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
            ]
        ),
        .testTarget(
            name: "NibHTTPTests",
            dependencies: [
                "NibHTTP",
                .product(name: "NibTestSupport", package: "NibTestSupport"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
            ]
        ),
    ]
)
