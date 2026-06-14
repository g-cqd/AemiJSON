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

// Dev-only tooling is gated behind `ADJSON_DEV` so packages that depend on ADJSON never resolve it
// (consumers keep just swift-syntax, which the macro needs). Contributors and CI set `ADJSON_DEV=1`
// to enable the DocC plugin (`swift package generate-documentation`) and build-time lint
// enforcement. The `format` / `lint` / `fetch-fixtures` command plugins carry no external
// dependencies, so they are always available without the flag.
let isDev = Context.environment["ADJSON_DEV"] != nil

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0")
]
if isDev {
    packageDependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"))
}

// Build-time formatting enforcement attaches to the library only in dev/CI. A build-tool plugin on
// a library target would otherwise run for everyone who depends on ADJSON, so it stays gated.
let adjsonBuildPlugins: [Target.PluginUsage] = isDev ? ["LintBuild"] : []

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
        // The full library: the engine plus Foundation interop, Codable, Schema, and the macros.
        .library(name: "ADJSON", targets: ["ADJSON"]),
        // The dependency-free engine on its own (no Foundation, no swift-syntax): tape parsing,
        // lazy navigation, JSONValue, and JSONPath/Pointer/Patch. For consumers that want a lean,
        // Foundation-free JSON core (e.g. zero-dependency libraries).
        .library(name: "ADJSONCore", targets: ["ADJSONCore"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .macro(
            name: "ADJSONMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            swiftSettings: strictSettings
        ),
        // The Foundation-free, swift-syntax-free engine: tape parse, lazy navigation
        // (JSONDocument/JSON/JSONValue), and query (JSONPath/Pointer/Patch). Zero
        // dependencies, so a strict zero-dependency consumer can adopt just this.
        .target(
            name: "ADJSONCore", dependencies: [], swiftSettings: strictSettings),
        .target(
            name: "ADJSON", dependencies: ["ADJSONCore", "ADJSONMacros"], swiftSettings: strictSettings,
            plugins: adjsonBuildPlugins),
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

        // Developer tooling. Command plugins are dependency-free (they drive the toolchain's
        // bundled `swift format`), so they impose nothing on packages that depend on ADJSON.
        .plugin(
            name: "Format",
            capability: .command(
                intent: .custom(verb: "format", description: "Format Swift sources with swift-format"),
                permissions: [.writeToPackageDirectory(reason: "Format Swift sources with swift-format")])),
        .plugin(
            name: "Lint",
            capability: .command(
                intent: .custom(verb: "lint", description: "Check formatting and shipped-library discipline"))),
        .plugin(
            name: "FetchFixtures",
            capability: .command(
                intent: .custom(
                    verb: "fetch-fixtures", description: "Download conformance and benchmark corpora"),
                permissions: [
                    .allowNetworkConnections(scope: .all(), reason: "Download third-party JSON corpora"),
                    .writeToPackageDirectory(reason: "Write fixtures into Tests and Benchmarks"),
                ])),
        .plugin(name: "LintBuild", capability: .buildTool()),
    ]
)
