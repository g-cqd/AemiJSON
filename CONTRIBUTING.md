# Contributing to ADJSON

Developer tooling lives in the package itself — SwiftPM plugins and committed git hooks — so
there are no shell scripts to run and nothing to install globally.

## One-time setup

Enable the repo's git hooks (pre-commit lint, pre-push test):

```sh
git config core.hooksPath .githooks
```

That's it. The toolchain's bundled `swift format` powers the plugins; no extra tools needed.

## Everyday commands

```sh
swift build                 # build the library
swift test                  # run the test + conformance suite
swift run -c release ADJSONBenchmarks

swift package format        # format in place  (add --allow-writing-to-package-directory if prompted)
swift package lint          # formatting gate + shipped-library discipline (what CI runs)
swift package fetch-fixtures \
  # downloads JSONTestSuite / JSONPath CTS / simdjson corpora
  # add: --allow-network-connections all --allow-writing-to-package-directory
```

`swift package lint` is the single source of truth for the lint rules: `swift format lint
--strict`, plus the shipped-library discipline (no force-unwrap / force-try / force-cast /
locale-sensitive `strtod` in `Sources/ADJSON`). Fix formatting with `swift package format`.

## Sanitizers

`--sanitize` instruments the whole graph (no manifest change needed). TSan and ASan are
**mutually exclusive**, so run them as separate passes:

```sh
# Tests — race / memory correctness over the full conformance corpus
swift test --sanitize=thread                        # data races (buffer pool, metrics)
swift test --sanitize=address --sanitize=undefined  # OOB / use-after-free in the unsafe scanner

# Benchmarks — reuse the large real-world corpora (canada/twitter/citm) as a stress harness
swift run --sanitize=thread  ADJSONBenchmarks
swift run --sanitize=address ADJSONBenchmarks
```

These catch what the test target's `-enable-actor-data-race-checks` (actor-isolation only)
cannot — the hot paths lean on `Unsafe*Pointer` / `Span` and there's a small shared-state
concurrency layer. **Don't read bench timings under a sanitizer**: TSan is ~5–15× slower and ASan
changes allocation layout, so the sanitized bench run is a correctness pass, not a measurement —
use the plain `swift run -c release ADJSONBenchmarks` for numbers. First run is slow (the graph,
including swift-syntax, rebuilds under instrumentation).

## The `ADJSON_DEV` flag

Heavier dev tooling is gated behind the `ADJSON_DEV` environment variable so that packages which
merely *depend on* ADJSON never resolve it (they keep only swift-syntax, needed by the macro).
Set it when you want:

```sh
# Build-time formatting enforcement (the LintBuild plugin attaches to the ADJSON target):
ADJSON_DEV=1 swift build      # fails the build on any formatting violation

# Generate the DocC documentation (pulls swift-docc-plugin):
ADJSON_DEV=1 swift package generate-documentation --target ADJSON
```

The `format`, `lint`, and `fetch-fixtures` command plugins are dependency-free and work without
the flag.

## Git hooks

Committed in `.githooks/` and enabled via `core.hooksPath` (above):

- **pre-commit** → `swift package lint` (check-only; blocks the commit on violations).
- **pre-push** → `swift test`.

## CI & documentation

A single workflow — **`.github/workflows/ci.yml`** — chains everything and only fans out after
the gate passes:

- **`build-test`** (macOS): lint → build → fixtures → test, in one job (one cache, warm build).
- **`platforms`**: a cross-platform compile matrix (iOS / tvOS / watchOS / visionOS), on
  `main` / manual dispatch.
- **`sanitizers`**: TSan + ASan passes over `swift test`, on `main` / manual dispatch (not PRs);
  each pass rebuilds the graph under instrumentation, so they stay off the PR path.
- **`docs`**: builds the DocC site and deploys it to GitHub Pages on `main` —
  <https://g-cqd.github.io/ADJSON/>. Requires Pages source = "GitHub Actions" in the repo
  settings (a one-time manual step).
