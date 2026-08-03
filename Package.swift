// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Pole",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Pole", targets: ["Pole"]),
        .executable(name: "PoleQualityEvaluation", targets: ["PoleQualityEvaluation"])
    ],
    targets: [
        .target(
            name: "PoleCore",
            path: "Sources/Pole",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Vision"),
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "PolePlatform",
            dependencies: ["PoleCore"],
            path: "Sources/PolePlatform"
        ),
        .executableTarget(
            name: "Pole",
            dependencies: ["PolePlatform"],
            path: "Sources/PoleApp"
        ),
        .executableTarget(
            name: "PoleQualityEvaluation",
            dependencies: ["PoleCore"],
            path: "Checks",
            exclude: ["PoleRegressionChecks.swift", "PoleRegressionTests.swift", "StandaloneCheckMain.swift"],
            sources: ["QualityEvaluationMain.swift"]
        ),
        .testTarget(
            name: "PoleCoreTests",
            dependencies: ["PoleCore"],
            path: "Checks",
            exclude: ["QualityEvaluationMain.swift", "StandaloneCheckMain.swift"],
            sources: ["PoleRegressionChecks.swift", "PoleRegressionTests.swift"]
        )
    ]
)
