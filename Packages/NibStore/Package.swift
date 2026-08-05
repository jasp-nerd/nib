// swift-tools-version: 6.2
import PackageDescription

// NibStore owns the folder-of-files repository, FSEvents watching, and the Keychain.
// Foundation + Security only — no AppKit, no SwiftUI.
//
// INVARIANT: secret values are never written to disk. They live in the Keychain under
// service `app.nib.secret`, account `<collectionUUID>/<envName>/<key>`.
let package = Package(
    name: "NibStore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NibStore", targets: ["NibStore"])
    ],
    dependencies: [
        .package(path: "../NibCore"),
        .package(path: "../NibTestSupport"),
    ],
    targets: [
        .target(
            name: "NibStore",
            dependencies: [.product(name: "NibCore", package: "NibCore")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
            ]
        ),
        .testTarget(
            name: "NibStoreTests",
            dependencies: [
                "NibStore",
                .product(name: "NibTestSupport", package: "NibTestSupport"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
            ]
        ),
    ]
)
