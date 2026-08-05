// swift-tools-version: 6.2
import PackageDescription

// The app as a plain SwiftPM executable.
//
// Why this exists alongside project.yml: it makes the whole app buildable, runnable and
// *measurable* with only Command Line Tools installed. `Tools/build-app.sh` wraps the
// executable this produces into a real .app bundle, which is what lets us hold the launch-time
// and bundle-size budgets from Phase 0 rather than waiting on a 40 GB Xcode install.
//
// Both paths compile the same sources in App/ and consume the same App/Info.plist, so they
// cannot drift. Xcode remains the better environment for Instruments and for the eventual
// notarized release; this is not a replacement for it.
//
// The `actool` gap is the one real limitation: an asset catalog needs Xcode to compile. Nib
// has no app icon yet, so it does not bite until Phase 8.
let package = Package(
    name: "Nib",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Nib", targets: ["NibApp"])
    ],
    dependencies: [
        .package(path: "Packages/NibCore"),
        .package(path: "Packages/NibHTTP"),
        .package(path: "Packages/NibStore"),
        .package(path: "Packages/NibInterchange"),
        .package(path: "Packages/NibUI"),
    ],
    targets: [
        .executableTarget(
            name: "NibApp",
            dependencies: [
                .product(name: "NibCore", package: "NibCore"),
                .product(name: "NibHTTP", package: "NibHTTP"),
                .product(name: "NibStore", package: "NibStore"),
                .product(name: "NibInterchange", package: "NibInterchange"),
                .product(name: "NibUI", package: "NibUI"),
            ],
            path: "App",
            // Info.plist is bundle metadata, not a target resource. Without this SPM tries to
            // process it and warns about an unhandled file.
            exclude: ["Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        )
    ]
)
