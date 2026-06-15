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

// The libFuzzer target is gated behind `ADJSON_FUZZ` so the default `swift build` is never asked to
// link a `main`-less, `-sanitize=fuzzer` executable (the combo only works under a fuzzer build).
// Contributors / CI set `ADJSON_FUZZ=1` and build it with the fuzzer sanitizer; see `Sources/ADJSONFuzz`.
let isFuzz = Context.environment["ADJSON_FUZZ"] != nil

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    // OrderedCollections backs the order-preserving eager `JSONValue.object`. It is Foundation-free
    // with zero transitive package dependencies (measured), so the core stays portable; it is the
    // one shipped dependency of `ADJSONCore` beyond the standard library.
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
]
if isDev {
    packageDependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"))
}

let orderedCollections: Target.Dependency = .product(name: "OrderedCollections", package: "swift-collections")

// Build-time formatting enforcement attaches to the library only in dev/CI. A build-tool plugin on
// a library target would otherwise run for everyone who depends on ADJSON, so it stays gated.
let adjsonBuildPlugins: [Target.PluginUsage] = isDev ? ["LintBuild"] : []

let package = Package(
    name: "ADJSON",
    // The deployment floor is pinned by `Synchronization`'s `Mutex`/`Atomic` (the library's only
    // OS-version-sensitive dependency), which ship in macOS 15 / iOS 18 / tvOS 18 / watchOS 11 /
    // visionOS 2. No code uses a newer-SDK API and there are no `@available` shims, so these are the
    // true minimums. Types gated to the 2025 SDKs (`UTF8Span`, `InlineArray`) are deliberately not
    // adopted, and `Span`/`RawSpan` back-deploy further still — adopting `UTF8Span`/`InlineArray`
    // would raise this floor or fragment the code with availability shims. (The Swift 6.3
    // tools-version is a *toolchain* requirement, not a deployment one.)
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        // The full library: the engine plus Foundation interop, Codable, Schema, and the macros.
        .library(name: "ADJSON", targets: ["ADJSON"]),
        // The engine on its own — Foundation-free and swift-syntax-free (its one dependency,
        // OrderedCollections, is itself Foundation-free with no transitive deps): tape parsing, lazy
        // navigation, JSONValue, and JSONPath/Pointer/Patch. For consumers that want a lean core.
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
        // (JSONDocument/JSON/JSONValue), and query (JSONPath/Pointer/Patch). Depends only on
        // OrderedCollections (Foundation-free, no transitive deps) for order-preserving eager objects.
        .target(
            name: "ADJSONCore", dependencies: [orderedCollections], swiftSettings: strictSettings),
        .target(
            name: "ADJSON", dependencies: ["ADJSONCore", "ADJSONMacros", orderedCollections],
            swiftSettings: strictSettings, plugins: adjsonBuildPlugins),
        .executableTarget(
            name: "ADJSONBenchmarks", dependencies: ["ADJSON", orderedCollections],
            swiftSettings: benchSettings),
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

if isFuzz {
    // `-parse-as-library` (libFuzzer supplies `main`) + `-sanitize=fuzzer` (instrument + link the
    // fuzzer runtime). Unsafe flags are fine here: the target is internal, gated, and never a product.
    // NOTE: `-sanitize=fuzzer` is a Linux capability of the Swift toolchain (the Darwin SDK rejects
    // it), so this target is built and run in the Linux CI fuzz job, not on macOS.
    package.targets.append(
        .executableTarget(
            name: "ADJSONFuzz",
            dependencies: ["ADJSON"],
            swiftSettings: strictSettings + [
                .unsafeFlags(["-parse-as-library", "-sanitize=fuzzer"])
            ],
            linkerSettings: [.unsafeFlags(["-sanitize=fuzzer"])]
        ))
}
