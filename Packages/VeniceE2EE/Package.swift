// swift-tools-version: 6.1
// VeniceE2EE: phone-side end-to-end encryption to Venice enclave models.
// See VENICE-E2EE.md at the repo root.

import PackageDescription

let package = Package(
    name: "VeniceE2EE",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VeniceE2EE", targets: ["VeniceE2EE"]),
        .executable(name: "venice-e2ee-spike", targets: ["venice-e2ee-spike"]),
    ],
    dependencies: [
        // secp256k1 ECDH (CryptoKit has P-256 only). Pinned exactly: the
        // package marks its API unstable.
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.24.0"),
    ],
    targets: [
        .target(
            name: "VeniceE2EE",
            dependencies: [.product(name: "P256K", package: "swift-secp256k1")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "venice-e2ee-spike",
            dependencies: ["VeniceE2EE"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VeniceE2EETests",
            dependencies: ["VeniceE2EE", .product(name: "P256K", package: "swift-secp256k1")],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
