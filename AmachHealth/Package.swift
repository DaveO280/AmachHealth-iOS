// swift-tools-version: 5.9
// Package.swift
// AmachHealth iOS App

import PackageDescription

let package = Package(
    name: "AmachHealth",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "AmachHealth",
            targets: ["AmachHealth"]
        ),
    ],
    dependencies: [
        // Privy iOS SDK for wallet integration
        // .package(url: "https://github.com/privy-io/privy-ios", from: "1.0.0"),

        // Additional dependencies as needed
    ],
    targets: [
        .target(
            name: "AmachHealth",
            dependencies: [
                // "PrivySDK",
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "AmachHealthTests",
            dependencies: ["AmachHealth"],
            path: "Tests"
        ),
    ]
)
