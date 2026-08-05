// swift-tools-version: 6.2
import PackageDescription

// NibInterchange holds every importer and exporter. Pure `Data` -> value types.
// Zero I/O, zero UI, so the whole suite is unit-testable against the fixture corpus
// and runs in milliseconds.
//
// INVARIANT: an import never silently drops anything. Whatever we cannot execute goes
// into the request's `preserved` block and round-trips untouched.
let package = Package(
    name: "NibInterchange",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NibInterchange", targets: ["NibInterchange"])
    ],
    dependencies: [
        .package(path: "../NibCore")
    ],
    targets: [
        .target(
            name: "NibInterchange",
            dependencies: [.product(name: "NibCore", package: "NibCore")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
            ]
        ),
        .testTarget(
            name: "NibInterchangeTests",
            dependencies: ["NibInterchange"],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
            ]
        ),
    ]
)
