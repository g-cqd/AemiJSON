// swift-tools-version: 6.4
import CompilerPluginSupport
import PackageDescription

// Maximum concurrency safety + stricter checking. These are dependency-safe (no unsafe
// flags), so the library can still be consumed via a version-pinned SwiftPM requirement.
// `.v6` language mode turns on complete strict-concurrency checking; the upcoming features
// tighten existentials and import visibility.
let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility")
]

// Compile-time type-check timing warnings (flag slow expressions / function bodies). These
// use unsafe flags, which would block version-based dependency resolution if placed on the
// library, so they live only on the internal (non-exported) benchmark + test targets.
// The budget is env-tunable because `treatAllWarnings(as: .error)` turns an overrun into a HARD
// build error while the measured quantity is type-check WALL TIME — structurally flaky on shared
// CI runners (observed 102–168 ms flips for bodies comfortably under 100 ms locally). CI exports
// AD_TYPECHECK_BUDGET_MS=250 to calibrate for runner noise; unset (local builds) it stays 100 so
// regressions still surface at developer-machine speed.
let typeCheckBudgetMS = Context.environment["AD_TYPECHECK_BUDGET_MS"].flatMap { Int($0) } ?? 100
let timingWarningFlags: [SwiftSetting] = [
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=\(typeCheckBudgetMS)",
        "-Xfrontend", "-warn-long-expression-type-checking=\(typeCheckBudgetMS)"
    ])
]

// Tests share the same 100ms budgets as the rest of the package — both per-EXPRESSION and
// whole-FUNCTION-body. The `@dynamicMemberLookup` `JSON` chains that previously pushed thorough test
// bodies past 100ms were fixed at the root (split into focused tests, big literals hoisted to typed
// `let`s, chained `#expect`s moved to the kit's typed `expectEqual`/`expectTrue` asserts) rather than
// papered over with a looser budget, so a regression past 100ms is once again a hard build error.
let testTimingWarningFlags: [SwiftSetting] = [
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=\(typeCheckBudgetMS)",
        "-Xfrontend", "-warn-long-expression-type-checking=\(typeCheckBudgetMS)"
    ])
]

// Benchmarks: strict + timing warnings only (no runtime instrumentation, so timings stay clean).
let benchSettings: [SwiftSetting] = strictSettings + timingWarningFlags

// Tests: looser function-body timing budget + runtime actor data-race checks.
let testSettings: [SwiftSetting] =
    strictSettings + testTimingWarningFlags + [.unsafeFlags(["-enable-actor-data-race-checks"])]

// Shipped kernel (the byte-level parser): strict + StrictMemorySafety + Lifetimes, matching the other
// AD-family kernels (ADFCore, ADHTMLCore, ADDBCore, ADServeCore). Every unsafe construct in the parser must
// be explicitly marked `unsafe`. Only `ADJSONCore` carries this; the umbrella / macros stay on strict.
let kernelSettings: [SwiftSetting] =
    strictSettings + [.strictMemorySafety(), .enableExperimentalFeature("Lifetimes")]

// Dev-only tooling is gated behind `ADJSON_DEV` so packages that depend on ADJSON never resolve it
// (consumers keep just swift-syntax, which the macro needs). Contributors and CI set `ADJSON_DEV=1`
// to enable the DocC plugin, the shared ADBuildTools `format` / `lint` / `LintBuild` plugins, and the
// benchmark suite. The local `coverage-check` / `bench-compare` / `fetch-fixtures` command plugins carry
// no external dependencies, so they stay available without the flag.
let isDev = Context.environment["ADJSON_DEV"] != nil

// The libFuzzer target is gated behind `ADJSON_FUZZ` so the default `swift build` is never asked to
// link a `main`-less, `-sanitize=fuzzer` executable (the combo only works under a fuzzer build).
// Contributors / CI set `ADJSON_FUZZ=1` and build it with the fuzzer sanitizer; see `Sources/ADJSONFuzz`.
let isFuzz = Context.environment["ADJSON_FUZZ"] != nil

// The `ADJSONNIO` adapter (swift-nio `ByteBuffer` interop) is gated behind `ADJSON_NIO` so swift-nio
// stays out of the default resolution graph — `ADJSON` / `ADJSONCore` consumers never fetch it. A
// server that wants the integration builds/resolves with `ADJSON_NIO=1` and depends on the
// `ADJSONNIO` product, which re-exports `ADJSONCore`. Same opt-in model as `ADJSON_DEV` / `ADJSON_FUZZ`.
let isNIO = Context.environment["ADJSON_NIO"] != nil

// ADFoundation supplies the shared low-level primitives (the `ADFCore` byte/number kernel),
// resolved from the published package.
let adfoundationDependency: Package.Dependency = .package(
    url: "https://github.com/g-cqd/ADFoundation.git", from: "0.1.0")

// ADConcurrency (the production `TaskProvider`/`Clock` seams the concurrent parse/decode paths use) and
// ADTestKit (the test-only kit) are now both vended by the ADFoundation umbrella package, so they
// resolve via `adfoundationDependency` above — there is no separate ADConcurrency / ADTestKit package.

var packageDependencies: [Package.Dependency] = [
    adfoundationDependency,
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    // OrderedCollections backs the order-preserving eager `JSONValue.object`. It is Foundation-free
    // with zero transitive package dependencies (measured), so the core stays portable; together with
    // `ADFCore` it is one of the two shipped dependencies of `ADJSONCore` beyond the standard library.
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0")
]
if isDev {
    // Shared lint/format tooling (Format/Lint/LintBuild plugins + canonical `.swift-format`).
    // Dev-only, resolved from the published `main` branch.
    packageDependencies.append(
        .package(url: "https://github.com/g-cqd/ADBuildTools.git", branch: "main"))
    packageDependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"))
    // ordo-one's statistically-rigorous benchmark framework (p-percentile latencies, malloc /
    // throughput metrics, CI-gated thresholds) — the project's single benchmark suite lives in
    // `Benchmarks/ADJSONSuite` and runs via `swift package benchmark`. Dev-only: the suite target is
    // added only under `ADJSON_DEV`, so consumers never resolve it.
    packageDependencies.append(
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.4.0"))
    // (ADTestKit is vended by the ADFoundation package now; the test target references it from there.)
}
if isNIO {
    // swift-nio (NIOCore) supplies `ByteBuffer`. Resolved only under `ADJSON_NIO`, so default
    // consumers of `ADJSON` / `ADJSONCore` never pull it into their dependency graph.
    packageDependencies.append(
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.50.0"))
}

let orderedCollections: Target.Dependency = .product(name: "OrderedCollections", package: "swift-collections")
// Shared low-level byte/number primitives. Only the engine (`ADJSONCore`) links it.
let adfCore: Target.Dependency = .product(name: "ADFCore", package: "ADFoundation")
// Runtime-dispatched SIMD byte kernels (the string-stop scan accelerates the tape parser's hot loop).
let adfKernels: Target.Dependency = .product(name: "ADFKernels", package: "ADFoundation")

// Build-time formatting enforcement attaches to the library only in dev/CI. A build-tool plugin on
// a library target would otherwise run for everyone who depends on ADJSON, so it stays gated.
let adjsonBuildPlugins: [Target.PluginUsage] =
    isDev ? [.plugin(name: "LintBuild", package: "ADBuildTools")] : []

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
        .visionOS(.v2)
    ],
    products: [
        // The full library: the engine plus Foundation interop, Codable, Schema, and the macros.
        .library(name: "ADJSON", targets: ["ADJSON"]),
        // The engine on its own — Foundation-free and swift-syntax-free (its dependencies,
        // OrderedCollections and ADFCore, are themselves Foundation-free with no transitive deps):
        // tape parsing, lazy navigation, JSONValue, and JSONPath/Pointer/Patch. For a lean core.
        .library(name: "ADJSONCore", targets: ["ADJSONCore"])
    ],
    dependencies: packageDependencies,
    targets: [
        .macro(
            name: "ADJSONMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "ADFMacroSupport", package: "ADFoundation")
            ],
            swiftSettings: strictSettings
        ),
        // The Foundation-free, swift-syntax-free engine: tape parse, lazy navigation
        // (JSONDocument/JSON/JSONValue), and query (JSONPath/Pointer/Patch). Depends on
        // OrderedCollections (order-preserving eager objects) and ADFCore (shared byte/number
        // primitives) — both Foundation-free with no transitive package deps, so the core stays portable.
        .target(
            name: "ADJSONCore", dependencies: [orderedCollections, adfCore, adfKernels],
            swiftSettings: kernelSettings),
        .target(
            // `adfCore` is declared directly (not only transitively via `ADJSONCore`) because the
            // umbrella links it itself — `EncoderBufferPool` uses `ADFCore.ByteBufferPool`.
            // `ADConcurrency` is the zero-dep, shipped-safe `TaskProvider` seam the concurrent
            // parse/decode paths default to `LiveTaskProvider` (production-identical); a test injects a
            // `TaskProviderSpy` (from the dev-only `ADTestKit`, which re-exports the same seam).
            name: "ADJSON",
            dependencies: [
                "ADJSONCore", "ADJSONMacros", orderedCollections, adfCore, adfKernels,
                .product(name: "ADConcurrency", package: "ADFoundation")
            ],
            swiftSettings: strictSettings, plugins: adjsonBuildPlugins),
        .testTarget(
            name: "ADJSONTests",
            dependencies: [
                "ADJSON",
                // Unconditional: 13 test files import ADTestKit with no `#if canImport` guard, so
                // gating this behind ADJSON_DEV made a plain `swift test` a hard compile failure.
                // ADFoundation is already a non-dev dependency, so this costs consumers nothing.
                .product(name: "ADTestKit", package: "ADFoundation"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ],
            resources: [.copy("Resources")],
            swiftSettings: testSettings
        ),

        // Format / lint / LintBuild come from the shared ADBuildTools dev dependency. The ADJSON-specific
        // command plugins below (coverage-check, bench-compare, fetch-fixtures) stay local.
        .plugin(
            name: "CoverageCheck",
            capability: .command(
                intent: .custom(verb: "coverage-check", description: "Gate line coverage against a floor"))),
        .plugin(
            name: "BenchCompare",
            capability: .command(
                intent: .custom(
                    verb: "bench-compare", description: "Render the ADJSON-vs-Foundation benchmark table"))),
        .plugin(
            name: "FetchFixtures",
            capability: .command(
                intent: .custom(
                    verb: "fetch-fixtures", description: "Download conformance and benchmark corpora"),
                permissions: [
                    .allowNetworkConnections(scope: .all(), reason: "Download third-party JSON corpora"),
                    .writeToPackageDirectory(reason: "Write fixtures into Tests and Benchmarks")
                ]))
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
    // Declare the explicit executable product so `swift build --product ADJSONFuzz` links the binary.
    // (`--target` only compiles the module: with `-parse-as-library` the `main` comes from libFuzzer
    // at link time, so without a product to drive the link no executable is produced.)
    package.products.append(.executable(name: "ADJSONFuzz", targets: ["ADJSONFuzz"]))
}

if isDev {
    // ordo-one package-benchmark suite (ADJSON_DEV-gated): the `swift package benchmark` plugin runs
    // these with statistical rigor and can gate CI on p-percentile thresholds. Lives under
    // `Benchmarks/` per the framework's convention.
    package.targets.append(
        .executableTarget(
            name: "ADJSONSuite",
            dependencies: [
                "ADJSON", orderedCollections,
                .product(name: "Benchmark", package: "benchmark")
            ],
            path: "Benchmarks/ADJSONSuite",
            swiftSettings: strictSettings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ))
    // ADJSONProbe (ADJSON_DEV-gated): a per-phase resource probe built on `ADFMetrics.ProcessProbe`.
    // The ordo-one suite reports per-benchmark percentiles; this attributes CPU, retired instructions,
    // and held footprint to each lifecycle phase (parse → materialize → query → encode), which the
    // suite can't break out. Run: `ADJSON_DEV=1 swift run -c release ADJSONProbe`.
    package.targets.append(
        .executableTarget(
            name: "ADJSONProbe",
            dependencies: ["ADJSON", .product(name: "ADFMetrics", package: "ADFoundation")],
            path: "Benchmarks/ADJSONProbe",
            swiftSettings: strictSettings
        ))
}

if isNIO {
    // The swift-nio interop product (ADJSON_NIO-gated): `ByteBuffer` ⇄ ADJSON. A superset of the
    // engine — it depends on and re-exports `ADJSONCore` (Foundation-free), and adds NIOCore only
    // here, so the base products stay dependency-clean.
    let nioCore: Target.Dependency = .product(name: "NIOCore", package: "swift-nio")
    package.products.append(.library(name: "ADJSONNIO", targets: ["ADJSONNIO"]))
    package.targets.append(
        .target(
            name: "ADJSONNIO", dependencies: ["ADJSONCore", orderedCollections, nioCore],
            swiftSettings: strictSettings))
    package.targets.append(
        .testTarget(name: "ADJSONNIOTests", dependencies: ["ADJSONNIO", nioCore], swiftSettings: testSettings))
}
