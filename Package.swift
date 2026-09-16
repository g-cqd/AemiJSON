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
// AD-family kernels (AemiKernel, ADHTMLCore, ADDBCore, ADServeCore). Every unsafe construct in the parser must
// be explicitly marked `unsafe`. Only `AemiJSONCore` carries this; the umbrella / macros stay on strict.
let kernelSettings: [SwiftSetting] =
    strictSettings + [.strictMemorySafety(), .enableExperimentalFeature("Lifetimes")]

// Dev-only tooling is gated behind `AEMIJSON_DEV` so packages that depend on AemiJSON never resolve it
// (consumers keep just swift-syntax, which the macro needs). Contributors and CI set `AEMIJSON_DEV=1`
// to enable the DocC plugin, the shared Aemi `format` / `lint` / `LintBuild` plugins, and the
// benchmark suite. The local `coverage-check` / `bench-compare` / `fetch-fixtures` command plugins carry
// no external dependencies, so they stay available without the flag.
let isDev = Context.environment["AEMIJSON_DEV"] != nil || Context.environment["ADJSON_DEV"] != nil

// The libFuzzer target is gated behind `AEMIJSON_FUZZ` so the default `swift build` is never asked to
// link a `main`-less, `-sanitize=fuzzer` executable (the combo only works under a fuzzer build).
// Contributors / CI set `AEMIJSON_FUZZ=1` and build it with the fuzzer sanitizer; see `Sources/AemiJSONFuzz`.
let isFuzz = Context.environment["AEMIJSON_FUZZ"] != nil || Context.environment["ADJSON_FUZZ"] != nil

// The `AemiJSONNIO` adapter (swift-nio `ByteBuffer` interop) is gated behind `AEMIJSON_NIO` so swift-nio
// stays out of the default resolution graph — `AemiJSON` / `AemiJSONCore` consumers never fetch it. A
// server that wants the integration builds/resolves with `AEMIJSON_NIO=1` and depends on the
// `AemiJSONNIO` product, which re-exports `AemiJSONCore`. Same opt-in model as `AEMIJSON_DEV` / `AEMIJSON_FUZZ`.
let isNIO = Context.environment["AEMIJSON_NIO"] != nil || Context.environment["ADJSON_NIO"] != nil

// Aemi supplies the shared low-level primitives (the `AemiKernel` byte/number kernel),
// resolved from the published package.
let aemiDependency: Package.Dependency = .package(
    url: "https://github.com/Aemi-Studio/aemi.git", branch: "main")

// AemiRuntime (the production `TaskProvider`/`Clock` seams the concurrent parse/decode paths use) and
// AemiTestKit (the test-only kit) are now both vended by the Aemi umbrella package, so they
// resolve via `aemiDependency` above — there is no separate AemiRuntime / AemiTestKit package.

var packageDependencies: [Package.Dependency] = [
    aemiDependency,
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    // OrderedCollections backs the order-preserving eager `JSONValue.object`. It is Foundation-free
    // with zero transitive package dependencies (measured), so the core stays portable; together with
    // `AemiKernel` it is one of the two shipped dependencies of `AemiJSONCore` beyond the standard library.
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0")
]
if isDev {
    // Shared lint/format tooling (Format/Lint/LintBuild plugins + canonical `.swift-format`).
    // Dev-only, resolved from the published `main` branch.
    packageDependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"))
    // ordo-one's statistically-rigorous benchmark framework (p-percentile latencies, malloc /
    // throughput metrics, CI-gated thresholds) — the project's single benchmark suite lives in
    // `Benchmarks/AemiJSONSuite` and runs via `swift package benchmark`. Dev-only: the suite target is
    // added only under `AEMIJSON_DEV`, so consumers never resolve it.
    packageDependencies.append(
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.4.0"))
    // (AemiTestKit is vended by the Aemi package now; the test target references it from there.)
}
if isNIO {
    // swift-nio (NIOCore) supplies `ByteBuffer`. Resolved only under `AEMIJSON_NIO`, so default
    // consumers of `AemiJSON` / `AemiJSONCore` never pull it into their dependency graph.
    packageDependencies.append(
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.50.0"))
}

let orderedCollections: Target.Dependency = .product(name: "OrderedCollections", package: "swift-collections")
// Shared low-level byte/number primitives. Only the engine (`AemiJSONCore`) links it.
let aemiKernel: Target.Dependency = .product(name: "AemiKernel", package: "aemi")
// Runtime-dispatched SIMD byte kernels (the string-stop scan accelerates the tape parser's hot loop).
let aemiKernels: Target.Dependency = .product(name: "AemiKernels", package: "aemi")

// Build-time formatting enforcement attaches to the library only in dev/CI. A build-tool plugin on
// a library target would otherwise run for everyone who depends on AemiJSON, so it stays gated.
let aemijsonBuildPlugins: [Target.PluginUsage] =
    isDev ? [.plugin(name: "LintBuild", package: "aemi")] : []

let package = Package(
    name: "AemiJSON",
    // The deployment floor is pinned by `Synchronization`'s `Mutex`/`Atomic` (the library's only
    // OS-version-sensitive dependency), which ship in macOS 15 / iOS 18 / tvOS 18 / watchOS 11 /
    // visionOS 2. No code uses a newer-SDK API and there are no `@available` shims, so these are the
    // true minimums. Types gated to the 2025 SDKs (`UTF8Span`, `InlineArray`) are deliberately not
    // adopted, and `Span`/`RawSpan` back-deploy further still — adopting `UTF8Span`/`InlineArray`
    // would raise this floor or fragment the code with availability shims. (The Swift 6.4
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
        .library(name: "AemiJSON", targets: ["AemiJSON"]),
        // The engine on its own — Foundation-free and swift-syntax-free (its dependencies,
        // OrderedCollections and AemiKernel, are themselves Foundation-free with no transitive deps):
        // tape parsing, lazy navigation, JSONValue, and JSONPath/Pointer/Patch. For a lean core.
        .library(name: "AemiJSONCore", targets: ["AemiJSONCore"]),
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
        // The Foundation-free, swift-syntax-free engine: tape parse, lazy navigation
        // (JSONDocument/JSON/JSONValue), and query (JSONPath/Pointer/Patch). Depends on
        // OrderedCollections (order-preserving eager objects) and AemiKernel (shared byte/number
        // primitives) — both Foundation-free with no transitive package deps, so the core stays portable.
        .target(
            name: "AemiJSONCore", dependencies: [orderedCollections, aemiKernel, aemiKernels],
            swiftSettings: kernelSettings),
        .target(
            // `aemiKernel` is declared directly (not only transitively via `AemiJSONCore`) because the
            // umbrella links it itself — `EncoderBufferPool` uses `AemiKernel.ByteBufferPool`.
            // `AemiRuntime` is the zero-dep, shipped-safe `TaskProvider` seam the concurrent
            // parse/decode paths default to `LiveTaskProvider` (production-identical); a test injects a
            // `TaskProviderSpy` (from the dev-only `AemiTestKit`, which re-exports the same seam).
            name: "AemiJSON",
            dependencies: [
                "AemiJSONCore", "AemiJSONMacros", orderedCollections, aemiKernel, aemiKernels,
                .product(name: "AemiRuntime", package: "aemi")
            ],
            swiftSettings: strictSettings, plugins: aemijsonBuildPlugins),
        .testTarget(
            name: "AemiJSONCompatibilityTests",
            dependencies: ["AemiJSON", "AemiJSONCore", "ADJSON", "ADJSONCore"],
            swiftSettings: testSettings),
        .testTarget(
            name: "AemiJSONTests",
            dependencies: [
                "AemiJSON",
                // Unconditional: 13 test files import AemiTestKit with no `#if canImport` guard, so
                // gating this behind AEMIJSON_DEV made a plain `swift test` a hard compile failure.
                // Aemi is already a non-dev dependency, so this costs consumers nothing.
                .product(name: "AemiTestKit", package: "aemi"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ],
            resources: [.copy("Resources")],
            swiftSettings: testSettings
        ),

        // Format / lint / LintBuild come from the shared Aemi dev dependency. The AemiJSON-specific
        // command plugins below (coverage-check, bench-compare, fetch-fixtures) stay local.
        .plugin(
            name: "CoverageCheck",
            capability: .command(
                intent: .custom(verb: "coverage-check", description: "Gate line coverage against a floor"))),
        .plugin(
            name: "BenchCompare",
            capability: .command(
                intent: .custom(
                    verb: "bench-compare", description: "Render the AemiJSON-vs-Foundation benchmark table"))),
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
            name: "AemiJSONFuzz",
            dependencies: ["AemiJSON"],
            swiftSettings: strictSettings + [
                .unsafeFlags(["-parse-as-library", "-sanitize=fuzzer"])
            ],
            linkerSettings: [.unsafeFlags(["-sanitize=fuzzer"])]
        ))
    // Declare the explicit executable product so `swift build --product AemiJSONFuzz` links the binary.
    // (`--target` only compiles the module: with `-parse-as-library` the `main` comes from libFuzzer
    // at link time, so without a product to drive the link no executable is produced.)
    package.products.append(.executable(name: "AemiJSONFuzz", targets: ["AemiJSONFuzz"]))
}

if isDev {
    // ordo-one package-benchmark suite (AEMIJSON_DEV-gated): the `swift package benchmark` plugin runs
    // these with statistical rigor and can gate CI on p-percentile thresholds. Lives under
    // `Benchmarks/` per the framework's convention.
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
        ))
    // AemiJSONProbe (AEMIJSON_DEV-gated): a per-phase resource probe built on `AemiMetrics.ProcessProbe`.
    // The ordo-one suite reports per-benchmark percentiles; this attributes CPU, retired instructions,
    // and held footprint to each lifecycle phase (parse → materialize → query → encode), which the
    // suite can't break out. Run: `AEMIJSON_DEV=1 swift run -c release AemiJSONProbe`.
    package.targets.append(
        .executableTarget(
            name: "AemiJSONProbe",
            dependencies: ["AemiJSON", .product(name: "AemiMetrics", package: "aemi")],
            path: "Benchmarks/AemiJSONProbe",
            swiftSettings: strictSettings
        ))
}

if isNIO {
    // The swift-nio interop product (AEMIJSON_NIO-gated): `ByteBuffer` ⇄ AemiJSON. A superset of the
    // engine — it depends on and re-exports `AemiJSONCore` (Foundation-free), and adds NIOCore only
    // here, so the base products stay dependency-clean.
    let nioCore: Target.Dependency = .product(name: "NIOCore", package: "swift-nio")
    package.products.append(.library(name: "AemiJSONNIO", targets: ["AemiJSONNIO"]))
    package.products.append(.library(name: "ADJSONNIO", targets: ["ADJSONNIO"]))
    package.targets.append(.target(name: "ADJSONNIO", dependencies: ["AemiJSONNIO"], swiftSettings: strictSettings))
    package.targets.append(
        .target(
            name: "AemiJSONNIO", dependencies: ["AemiJSONCore", orderedCollections, nioCore],
            swiftSettings: strictSettings))
    package.targets.append(
        .testTarget(name: "AemiJSONNIOTests", dependencies: ["AemiJSONNIO", nioCore], swiftSettings: testSettings))
}
