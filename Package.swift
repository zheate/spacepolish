// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SpacePolish",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SpacePolish", targets: ["SpacePolish"])
    ],
    targets: [
        .executableTarget(
            name: "SpacePolish",
            path: "Sources/SpacePolish",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Security")
            ]
        )
    ]
)
