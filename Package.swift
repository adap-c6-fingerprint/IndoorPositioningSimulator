// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "IMDFPositioningSimulator",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "IndoorPositioningSimulation",
            targets: ["IndoorPositioningSimulation"]
        ),
        .executable(
            name: "IMDFSimulator",
            targets: ["IMDFSimulator"]
        )
    ],
    targets: [
        .target(name: "IndoorPositioningSimulation"),
        .executableTarget(
            name: "IMDFSimulator",
            dependencies: ["IndoorPositioningSimulation"]
        ),
        .testTarget(
            name: "IndoorPositioningSimulationTests",
            dependencies: ["IndoorPositioningSimulation"]
        )
    ]
)
