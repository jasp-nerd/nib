// swift-tools-version: 6.2
import PackageDescription

// NibCore is PURE. Foundation only — no AppKit, no SwiftUI, no I/O.
// Every model here is a Sendable struct or enum. No classes.
// This is what keeps strict concurrency painless across the MainActor boundary in NibUI.
let package = Package(
    name: "NibCore",
    platforms: [.macOS(.v26)],
    products: [
        // No `type:` — SPM links this statically. A `.dynamic` here embeds a
        // framework and blows the 5 MB bundle budget. See Tools/check-boundaries.sh.
        .library(name: "NibCore", targets: ["NibCore"])
    ],
    targets: [
        .target(
            name: "NibCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
            ]
        ),
        .testTarget(
            name: "NibCoreTests",
            dependencies: ["NibCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
            ]
        ),
    ]
)
