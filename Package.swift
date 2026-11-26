// swift-tools-version: 6.4
import CompilerPluginSupport
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility")
]

let typeCheckBudgetMS = Context.environment["AD_TYPECHECK_BUDGET_MS"].flatMap { Int($0) } ?? 100
let timingWarningFlags: [SwiftSetting] = [
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=\(typeCheckBudgetMS)",
        "-Xfrontend", "-warn-long-expression-type-checking=\(typeCheckBudgetMS)"
    ])
]

let testTimingWarningFlags: [SwiftSetting] = [
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=\(typeCheckBudgetMS)",
        "-Xfrontend", "-warn-long-expression-type-checking=\(typeCheckBudgetMS)"
    ])
]

let benchSettings: [SwiftSetting] = strictSettings + timingWarningFlags

let testSettings: [SwiftSetting] =
    strictSettings + testTimingWarningFlags + [.unsafeFlags(["-enable-actor-data-race-checks"])]

let kernelSettings: [SwiftSetting] =
    strictSettings + [.strictMemorySafety(), .enableExperimentalFeature("Lifetimes")]

let isDev = Context.environment["AEMIJSON_DEV"] != nil || Context.environment["ADJSON_DEV"] != nil

let isFuzz = Context.environment["AEMIJSON_FUZZ"] != nil || Context.environment["ADJSON_FUZZ"] != nil

let isNIO = Context.environment["AEMIJSON_NIO"] != nil || Context.environment["ADJSON_NIO"] != nil

let aemiDependency: Package.Dependency = .package(
    url: "https://github.com/Aemi-Studio/aemi.git",
    revision: "9f8d1a3eafed0ad23919b9c68d33606632ce0659"
)

var packageDependencies: [Package.Dependency] = [
    aemiDependency,
    .package(url: "https://github.com/g-cqd/AemiRegex.git", revision: "1b58215ac7266f8c847065f0cb63ab1cc75b3bc9"),
    .package(url: "https://github.com/swiftlang/swift-syntax.git", "603.0.0" ..< "605.0.0"),
    .package(url: "https://github.com/apple/swift-collections.git", "1.7.1" ..< "1.8.0")
]
if isDev {
    packageDependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0")
    )
    packageDependencies.append(
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.0")
    )
}
if isNIO {
    packageDependencies.append(
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0")
    )
}

let orderedCollections: Target.Dependency = .product(name: "OrderedCollections", package: "swift-collections")
let aemiKernel: Target.Dependency = .product(name: "AemiKernel", package: "aemi")
let aemiKernels: Target.Dependency = .product(name: "AemiKernels", package: "aemi")
let aemiRegex: Target.Dependency = .product(name: "AemiRegex", package: "aemiregex")

let aemijsonBuildPlugins: [Target.PluginUsage] =
    isDev ? [.plugin(name: "LintBuild", package: "aemi")] : []

let package = Package(
    name: "AemiJSON",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
    ],
    products: [
        .library(name: "AemiJSON", targets: ["AemiJSON"]),
        .library(name: "AemiJSONCore", targets: ["AemiJSONCore"]),
        .library(name: "AemiJSONRPC", targets: ["AemiJSONRPC"]),
        .library(name: "ADJSON", targets: ["ADJSON"]),
        .library(name: "ADJSONCore", targets: ["ADJSONCore"])
    ],
    dependencies: packageDependencies,
    targets: [
        .target(name: "ADJSON", dependencies: ["AemiJSON"], swiftSettings: strictSettings),
        .target(name: "ADJSONCore", dependencies: ["AemiJSONCore"], swiftSettings: strictSettings),
        .macro(
            name: "AemiJSONMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "AemiMacroSupport", package: "aemi")
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "AemiJSONCore",
            dependencies: [orderedCollections, aemiKernel, aemiKernels, aemiRegex],
            swiftSettings: kernelSettings
        ),
        .target(
            name: "AemiJSON",
            dependencies: [
                "AemiJSONCore", "AemiJSONMacros", orderedCollections, aemiKernel, aemiKernels, aemiRegex,
                .product(name: "AemiRuntime", package: "aemi")
            ],
            swiftSettings: strictSettings,
            plugins: aemijsonBuildPlugins
        ),
        .target(
            name: "AemiJSONRPC",
            dependencies: [
                "AemiJSONCore", orderedCollections, aemiKernels, .product(name: "AemiRuntime", package: "aemi")
            ],
            swiftSettings: strictSettings + [.strictMemorySafety()],
            plugins: aemijsonBuildPlugins
        ),
        .testTarget(
            name: "AemiJSONRPCTests",
            dependencies: ["AemiJSONRPC", "AemiJSONCore", .product(name: "AemiRuntime", package: "aemi")],
            swiftSettings: testSettings
        ),
        .testTarget(
            name: "AemiJSONCompatibilityTests",
            dependencies: ["AemiJSON", "AemiJSONCore", "ADJSON", "ADJSONCore"],
            swiftSettings: testSettings
        ),
        .testTarget(
            name: "AemiJSONTests",
            dependencies: [
                "AemiJSON",
                .product(name: "AemiTestKit", package: "aemi"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ],
            resources: [.copy("Resources")],
            swiftSettings: testSettings
        ),

        .plugin(
            name: "CoverageCheck",
            capability: .command(
                intent: .custom(verb: "coverage-check", description: "Gate line coverage against a floor")
            )
        ),
        .plugin(
            name: "BenchCompare",
            capability: .command(
                intent: .custom(
                    verb: "bench-compare",
                    description: "Render the AemiJSON-vs-Foundation benchmark table"
                )
            )
        ),
        .plugin(
            name: "FetchFixtures",
            capability: .command(
                intent: .custom(
                    verb: "fetch-fixtures",
                    description: "Download conformance and benchmark corpora"
                ),
                permissions: [
                    .allowNetworkConnections(scope: .all(), reason: "Download third-party JSON corpora"),
                    .writeToPackageDirectory(reason: "Write fixtures into Tests and Benchmarks")
                ]
            )
        )
    ]
)

if isFuzz {
    package.targets.append(
        .executableTarget(
            name: "AemiJSONFuzz",
            dependencies: ["AemiJSON"],
            swiftSettings: strictSettings + [
                .unsafeFlags(["-parse-as-library", "-sanitize=fuzzer"])
            ],
            linkerSettings: [.unsafeFlags(["-sanitize=fuzzer"])]
        )
    )
    package.products.append(.executable(name: "AemiJSONFuzz", targets: ["AemiJSONFuzz"]))
}

if isDev {
    package.targets.append(
        .executableTarget(
            name: "AemiJSONSuite",
            dependencies: [
                "AemiJSON", orderedCollections,
                .product(name: "Benchmark", package: "benchmark")
            ],
            path: "Benchmarks/AemiJSONSuite",
            swiftSettings: strictSettings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        )
    )
    package.targets.append(
        .executableTarget(
            name: "AemiJSONProbe",
            dependencies: ["AemiJSON", .product(name: "AemiMetrics", package: "aemi")],
            path: "Benchmarks/AemiJSONProbe",
            swiftSettings: strictSettings
        )
    )
}

if isNIO {
    let nioCore: Target.Dependency = .product(name: "NIOCore", package: "swift-nio")
    package.products.append(.library(name: "AemiJSONNIO", targets: ["AemiJSONNIO"]))
    package.products.append(.library(name: "ADJSONNIO", targets: ["ADJSONNIO"]))
    package.targets.append(.target(name: "ADJSONNIO", dependencies: ["AemiJSONNIO"], swiftSettings: strictSettings))
    package.targets.append(
        .target(
            name: "AemiJSONNIO",
            dependencies: ["AemiJSONCore", orderedCollections, nioCore],
            swiftSettings: strictSettings
        )
    )
    package.targets.append(
        .testTarget(name: "AemiJSONNIOTests", dependencies: ["AemiJSONNIO", nioCore], swiftSettings: testSettings)
    )
}
