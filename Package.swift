// swift-tools-version: 6.3
import CompilerPluginSupport
import PackageDescription

// Maximum concurrency safety + stricter checking. These are dependency-safe (no unsafe
// flags), so the library can still be consumed via a version-pinned SwiftPM requirement.
// `.v6` language mode turns on complete strict-concurrency checking; the upcoming features
// tighten existentials and import visibility.
let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

// Compile-time type-check timing warnings (flag slow expressions / function bodies). These
// use unsafe flags, which would block version-based dependency resolution if placed on the
// library, so they live only on the internal (non-exported) benchmark + test targets.
let timingWarningFlags: [SwiftSetting] = [
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=100",
        "-Xfrontend", "-warn-long-expression-type-checking=100",
    ])
]

// Benchmarks: strict + timing warnings only (no runtime instrumentation, so timings stay clean).
let benchSettings: [SwiftSetting] = strictSettings + timingWarningFlags

// Tests: additionally enable runtime actor data-race checks.
let testSettings: [SwiftSetting] =
    strictSettings + timingWarningFlags + [.unsafeFlags(["-enable-actor-data-race-checks"])]

let package = Package(
    name: "ADJSON",
    // macOS is intentionally one generation below the device platforms: everything the library
    // needs is available there (`Synchronization`'s Atomic/Mutex ship in macOS 15, and
    // `Span`/`RawSpan` back-deploy further still), so there's no reason to force macOS 26. Types
    // gated to the 2025 SDKs (`UTF8Span`, `InlineArray`) are therefore not adopted yet — that
    // would raise this floor or fragment the code with availability shims.
    platforms: [
        .macOS(.v15),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26),
    ],
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
            ],
            swiftSettings: strictSettings
        ),
        .target(name: "ADJSON", dependencies: ["ADJSONMacros"], swiftSettings: strictSettings),
        .executableTarget(name: "ADJSONBenchmarks", dependencies: ["ADJSON"], swiftSettings: benchSettings),
        .testTarget(
            name: "ADJSONTests",
            dependencies: [
                "ADJSON",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            resources: [.copy("Resources")],
            swiftSettings: testSettings
        ),
    ]
)
