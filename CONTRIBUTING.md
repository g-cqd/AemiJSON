# Contributing to AemiJSON

Developer tooling lives in the package itself — SwiftPM plugins and committed git hooks — so
there are no shell scripts to run and nothing to install globally.

## One-time setup

Enable the repo's git hooks (pre-commit lint, pre-push test):

```sh
git config core.hooksPath .githooks
```

That's it. The toolchain's bundled `swift format` powers the plugins; no extra tools needed.

**Benchmarks only:** the ordo-one `package-benchmark` dependency (pulled into the `AEMIJSON_DEV=1`
graph) needs the system **jemalloc** headers — `brew install jemalloc` on macOS (`libjemalloc-dev`
on Linux). Without it, `AEMIJSON_DEV=1 swift …` fails at dependency-scan time. Plain `swift build` /
`swift test` don't need it.

## Everyday commands

```sh
swift build                 # build the library
swift test                  # run the test + conformance suite
swift test --enable-code-coverage \
  && swift package coverage-check --floor 80   # the coverage gate CI runs (see Coverage below)
AEMIJSON_DEV=1 swift package benchmark   # the ordo-one/benchmark suite (Benchmarks/AemiJSONSuite)
swift package bench-compare            # AemiJSON-vs-Foundation table (build the suite first; see Benchmarks)

swift package format        # format in place  (add --allow-writing-to-package-directory if prompted)
swift package lint          # formatting gate + shipped-library discipline (what CI runs)
swift package fetch-fixtures \
  # downloads JSONTestSuite / JSONPath CTS / simdjson corpora
  # add: --allow-network-connections all --allow-writing-to-package-directory
```

`swift package lint` is the single source of truth for the lint rules: a `swift format lint --strict`
formatting pass over the package, plus shipped-library discipline on `Sources/AemiJSON` **and**
`Sources/AemiJSONCore`. The latter forbids **force-unwrap / force-cast / force-try** via swift-format's
AST rules (`NeverForceUnwrap`, `NeverUseForceTry`, run with the project config plus those two switched
on — so every `x!` / `as!` / `try!` is caught, not a fixed pattern set) and a locale-sensitive
`strtod`. Annotate a reviewed force-unwrap with `// swift-format-ignore: NeverForceUnwrap` on the line
above it. Fix formatting with `swift package format`.

## Coverage

CI gates on line coverage of the shipped library sources (`Tests` / `.build` / `Benchmarks`
excluded). Reproduce the gate locally:

```sh
swift test --enable-code-coverage
swift package coverage-check --floor 80     # per-file report + verdict; non-zero exit below the floor
```

The `coverage-check` command plugin (macOS) reads the test profile, runs `xcrun llvm-cov`, and fails
below the floor — the exact gate CI runs. Keep new code covered; the floor is set below the current
number and ratchets up over time.

## Sanitizers

`--sanitize` instruments the whole graph (no manifest change needed). TSan and ASan are
**mutually exclusive**, so run them as separate passes:

```sh
# Tests — race / memory correctness over the full conformance + JSONTestSuite + simdjson corpora
swift test --sanitize=thread                        # data races (buffer pool, metrics)
swift test --sanitize=address --sanitize=undefined  # OOB / use-after-free in the unsafe scanner
```

The test target already drives the large real-world corpora (canada/twitter/citm, JSONTestSuite,
the JSONPath CTS) through the scanner and the shared-state concurrency layer, so `swift test
--sanitize` doubles as the stress harness. These catch what `-enable-actor-data-race-checks`
(actor-isolation only) cannot — the hot paths lean on `Unsafe*Pointer`. For coverage-guided
input generation see the **libFuzzer** section below; for throughput numbers use
`AEMIJSON_DEV=1 swift package benchmark` (never under a sanitizer — ASan changes allocation layout and
TSan is ~5–15× slower, so a sanitized run is a correctness pass, not a measurement).

## Coverage-guided fuzzing (libFuzzer)

The `AemiJSONFuzz` target drives `AemiJSON.parse` (strict / lenient / json5 / iJSON), lazy navigation,
`JSONValue(parsing:)`, `JSONPath`, and `SQLiteJSONPath` from one `LLVMFuzzerTestOneInput` entry. It
is gated behind `AEMIJSON_FUZZ` (so the default `swift build` never tries to link a `main`-less
fuzzer executable) and built with `-sanitize=fuzzer -parse-as-library`.

`-sanitize=fuzzer` is a **Linux** capability of the Swift toolchain (the Darwin SDK rejects it), so
run it on Linux (the CI `fuzz` job does this on every `main` push / dispatch, time-boxed, seeded
from the vendored corpora + CTS):

```sh
AEMIJSON_FUZZ=1 swift build --product AemiJSONFuzz
"$(AEMIJSON_FUZZ=1 swift build --product AemiJSONFuzz --show-bin-path)/AemiJSONFuzz" corpus -max_total_time=300
```

A crash writes a `crash-*` reproducer; commit it as a regression test under `Tests/`.

## The `AEMIJSON_DEV` flag

Heavier dev tooling is gated behind the `AEMIJSON_DEV` environment variable so that packages which
merely *depend on* AemiJSON never resolve it (they keep only swift-syntax, needed by the macro).
Set it when you want:

```sh
# Build-time formatting enforcement (the LintBuild plugin attaches to the AemiJSON target):
AEMIJSON_DEV=1 swift build      # fails the build on any formatting violation

# Generate the DocC documentation (pulls swift-docc-plugin):
AEMIJSON_DEV=1 swift package generate-documentation --target AemiJSON
```

The `format`, `lint`, and `fetch-fixtures` command plugins work without the flag. `AEMIJSON_DEV`
also pulls swift-docc-plugin (docs) and package-benchmark; consumers do not resolve those tools.
`swift-collections` is a shipped dependency of `AemiJSONCore` for ordered objects.

## The `AEMIJSON_NIO` flag

The swift-nio adapter (`AemiJSONNIO`) is gated behind `AEMIJSON_NIO` so swift-nio stays out of the default
resolution graph — consumers of `AemiJSON` / `AemiJSONCore` never fetch it. Build and test it with:

```sh
AEMIJSON_NIO=1 swift build
AEMIJSON_NIO=1 swift test --filter AemiJSONNIOTests
```

## Benchmarks & the regression baseline

```sh
AEMIJSON_DEV=1 swift package benchmark                         # full ordo-one/benchmark suite
AEMIJSON_DEV=1 swift build -c release --product AemiJSONSuite    # build the suite once, then:
swift package bench-compare                                  # AemiJSON-vs-Foundation speedup table
```

Regression gating compares each run against a committed baseline under `.benchmarkBaselines/main`.
Hosted-runner timings differ from a local machine, so generate the baseline **on the CI runner**:
trigger the workflow (`workflow_dispatch`) with `update_baseline=true`, download the
`benchmark-baseline-main` artifact, and commit it with `git add -f .benchmarkBaselines/main` (local
baselines are gitignored). CI then reports drift against it — advisory until the runner proves stable
enough to promote to a hard gate.

## Dependencies & `Package.resolved`

`AemiJSONCore` depends on AemiKernel and `swift-collections`' OrderedCollections. The full library
also depends on swift-syntax for its macros and AemiRuntime for concurrent operations. The Aemi
revision is pinned; swift-syntax uses a bounded version range. The documentation and benchmark
tools remain behind `AEMIJSON_DEV`, and the fuzzer remains behind `AEMIJSON_FUZZ`.

`swift-collections` starts at 1.7.1. Version 1.7.0 compiled borrowing helpers that reference
`_swift_initBorrow`, a Swift 6.4 runtime symbol that runtimes before macOS 27 lack, so a test bundle
failed to load on macOS 26 (apple/swift-collections#733). 1.7.1 removed the reference. Checked on
2026-10-18: the swift-collections objects built for this package reference the same 28 Swift runtime
symbols with 1.7.3 as with 1.6.0, while 1.7.0 adds `_swift_initBorrow` — the check detects the defect.

`Package.resolved` is **gitignored** (the library convention — an application pins exact versions,
a library lets its consumers' resolution win). A fresh checkout resolves dependencies within the
manifest's ranges and the pinned Aemi revision.

## Git hooks

Committed in `.githooks/` and enabled via `core.hooksPath` (above):

- **pre-commit** → `.ci/swift-ci run quality` (the quality gate CI runs), then the internal-tag check.
- **pre-push** → `.ci/swift-ci run quality`, then `swift test -c release --enable-testable-imports` (release
  is what ships; the scratch path is fixed so the release build is reused between pushes).

`.ci/swift-ci` builds and runs the swift-ci commit `.github/workflows/ci.yml` pins, once, so a hook and CI run
the same checks with the same tool versions. `.ci/swift-ci local` runs quality and the debug tests (fixtures
included).

## Static analysis

Quality runs swift-format, the SwiftLint metrics, the shipped-library discipline (no force unwrap or `try!`,
no `strtod` in `Sources/AemiJSON` and `Sources/AemiJSONCore`; no inline PRNG, untyped `#expect(throws:)` or
wall-clock assertion in `Tests`), then [deadwood](https://github.com/g-cqd/deadwood) (unused code),
[dolly](https://github.com/g-cqd/dolly) (duplicated code) and [arcleak](https://github.com/g-cqd/arcleak)
(retain cycles and leaks) over `Sources` and `Tests` under `--strict`. The analyzers are syntax-level, so they
need no build, and swift-ci's tool lock pins each to a release **and to the SHA-256 of its archive** (checked
before anything runs). Their scope and rules live in `.ci/action.json`.

A finding ends one of three ways: fix it, name the abstraction the duplicate was missing, or accept it where
it is, with a reason, on the line above the anchor:

```swift
// @dl:accept -- <why the duplication is intentional>     (dolly)
// @dw:accept -- <why the declaration must stay>          (deadwood)
// @al:accept -- <why the capture is safe>                (arcleak)
// lint:allow                                             (a reviewed discipline exception, on the line)
```

`.ci/baselines/dolly.json` is the one exception: the duplication that predates the gate (adopted with 96 clone
groups in `Sources`, and 101 test-code notes). A finding the baseline holds does not fail; a new one does. It is
for legacy debt, never for new code. Fingerprints hash rule, path, line and column, so an edit above a baselined
finding brings it back: shrink the baseline by refactoring, and regenerate it only afterwards
(`.ci/swift-ci baseline`, with the pinned tools). `Benchmarks/` is left out of the corpus: the benchmark plugin
finds a global named `benchmarks` by name, which no syntax-level analyzer can see, so every benchmark reads as
dead code.

## CI & documentation

**`.github/workflows/ci.yml`** calls the family's pinned swift-ci workflow, configured by `.ci/action.json`
(quality; Linux debug, release and AddressSanitizer; the flag-free consumer build; macOS debug, with fixtures
fetched first), next to this package's own jobs. **`.ci/README.md`** lists what runs when: the path-gated macOS
sanitizers, `api-stability` on pull requests, the Apple-platform builds, libFuzzer, the benchmarks and the
DocC site, built with warnings as errors and deployed to GitHub Pages from `main`
(<https://g-cqd.github.io/ADJSON/>; Pages source must be "GitHub Actions" in the repository settings).

### Apple-platform builds

CI uses the pinned Swift toolchain's `swift build --sdk ... --triple ...` to build
for iOS 18, tvOS 18, watchOS 11 (both device architectures), and visionOS 2.
This keeps manifest resolution on
Swift 6.4 while using the SDKs from the selected Xcode. A failed platform build
fails the CI workflow. Xcode's embedded older SwiftPM does not resolve the package.
