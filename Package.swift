// swift-tools-version: 6.4
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "ADJSON",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ADJSON", targets: ["ADJSON"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0")
    ],
    targets: [
        .macro(
            name: "ADJSONMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(name: "ADJSON", dependencies: ["ADJSONMacros"]),
        .executableTarget(name: "ADJSONBenchmarks", dependencies: ["ADJSON"]),
        .testTarget(
            name: "ADJSONTests",
            dependencies: [
                "ADJSON",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            resources: [.copy("Resources")]
        ),
    ]
)
