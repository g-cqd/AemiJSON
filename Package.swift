// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ADJSON",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ADJSON", targets: ["ADJSON"])
    ],
    targets: [
        .target(name: "ADJSON"),
        .executableTarget(name: "ADJSONBenchmarks", dependencies: ["ADJSON"]),
        .testTarget(
            name: "ADJSONTests",
            dependencies: ["ADJSON"],
            resources: [.copy("Resources")]
        ),
    ]
)
