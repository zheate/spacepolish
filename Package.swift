// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Pole",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Pole", targets: ["Pole"])
    ],
    targets: [
        .executableTarget(
            name: "Pole",
            path: "Sources/Pole",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Security")
            ]
        )
    ]
)
