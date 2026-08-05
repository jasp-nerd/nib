// swift-tools-version: 6.2
import PackageDescription

// Shared helpers for test targets only. Nothing in the app depends on this, so it is never
// linked into the shipped binary and cannot affect the size budget.
//
// It exists because more than one package needs the same localhost HTTP server: NibHTTP tests the
// engine against it, and NibUI tests the whole spec -> builder -> engine -> response chain against
// it. Phase 4's Postman fixture corpus will live here too.
let package = Package(
    name: "NibTestSupport",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NibTestSupport", targets: ["NibTestSupport"])
    ],
    targets: [
        .target(
            name: "NibTestSupport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
            ]
        )
    ]
)
