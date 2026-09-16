# AemiJSON

**Fast, safe, standards-first JSON for Swift 6.** A drop-in alternative to Foundation's
`JSONDecoder` / `JSONEncoder` / `JSONSerialization` — with JSON Schema, JSONPath, JSON
Pointer, and JSON Patch in the box. Built on a single-pass **tape** with lazy, on-demand
materialization, so reading two fields out of a megabyte never decodes the rest.

```swift
import AemiJSON

// Parse once. Read only what you touch — nil-safe, even mid-chain.
let doc  = try AemiJSON.parse(data)
let name = doc.root.user.name.string          // String?

// Or map straight to your types — like Foundation, only faster.
let users = try AemiJSON.JSONDecoder().decode([User].self, from: data)
```

That's the whole learning curve for the common case. Everything else is opt-in.

## Why AemiJSON

- **Quick** — ~1 GB/s tape parsing; lazy access skips what you don't read. ([Performance](#performance))
- **Safe** — value-typed, `Sendable`, Swift 6 strict concurrency; parses off the main actor.
- **Correct** — strict RFC 8259 by default; passes the full nst/JSONTestSuite (318/318).
- **Complete** — Schema (validate, infer, or generate from a type with `@Schemable`), JSONPath,
  Pointer, Patch, and Merge Patch — all in one package.
- **Familiar** — `AemiJSON.JSONDecoder` / `AemiJSON.JSONEncoder` mirror Foundation's API.
- **Lean** — the engine ships as a separate **`AemiJSONCore`** product with *no* Foundation and *no*
  swift-syntax, for dependency-strict consumers. ([Install](#install))

## Migration from ADJSON

The implementation modules are now `AemiJSON` and `AemiJSONCore`. Existing
`import ADJSON` and `import ADJSONCore` statements remain supported through
re-export targets, and `ADJSON.parse`, codec names, and protocol conformances
retain compatibility aliases. There is one implementation behind both names.

The remote repository still uses the `g-cqd/ADJSON` URL during this migration,
so SwiftPM's package identity remains `ADJSON`. The new products require this
revision to be published; older tags do not contain them.

## Install

```swift
// Package.swift
.package(url: "https://github.com/g-cqd/ADJSON.git", branch: "main")
```

```swift
.target(name: "MyApp", dependencies: [.product(name: "AemiJSON", package: "ADJSON")])
```

Reference the namespaced types as `AemiJSON.JSONDecoder` etc. where Foundation is also imported.

### Foundation-free core

Want only the engine — tape parsing, lazy navigation, `JSONValue`, and JSONPath/Pointer/Patch —
with **no Foundation and no swift-syntax** in your dependency graph (just `OrderedCollections` and
`ADFCore`, both Foundation-free with no transitive deps)? Depend on the `AemiJSONCore` product instead:

```swift
.target(name: "MyEngine", dependencies: [.product(name: "AemiJSONCore", package: "ADJSON")])
```

`import AemiJSON` re-exports `AemiJSONCore`, so the full library is a strict superset: the `Data`
conveniences, Codable, Schema, and the macros live only in the umbrella module.

### swift-nio interop (`AemiJSONNIO`)

Server-side consumers can opt into a swift-nio bridge — zero-copy `AemiJSON.parse(ByteBuffer)` and a
`ByteBuffer.writeJSON(_:options:)` sink — via the `AemiJSONNIO` product, a superset that re-exports the
Foundation-free `AemiJSONCore`. It is **gated behind `AEMIJSON_NIO`** so swift-nio never enters the
default resolution graph; enable it when resolving/building:

```swift
// Build/resolve with AEMIJSON_NIO=1, then:
.target(name: "MyServer", dependencies: [.product(name: "AemiJSONNIO", package: "ADJSON")])
```

```swift
import AemiJSONNIO  // re-exports AemiJSONCore — JSON, JSONValue, AemiJSON.parse — without Foundation

func echo(_ buffer: ByteBuffer) throws -> ByteBuffer {
    let doc = try AemiJSON.parse(buffer)            // zero-copy: borrows the buffer's storage in place
    var out = ByteBuffer()
    try out.writeJSON(["ok": true, "name": .string(doc.root.name.string ?? "")])
    return out
}
```

**Requirements:** Swift 6.3+ toolchain (built and tested on 6.3); macOS 15+ / iOS 18+ /
tvOS 18+ / watchOS 11+ / visionOS 2+ (the floor is set by the Synchronization framework's
`Atomic`/`Mutex`).

## A quick tour

```swift
import AemiJSON

// 1. Lazy navigation — nothing is materialized until you read it.
let doc   = try AemiJSON.parse(data)
let name  = doc.root.user.name.string           // String?
let first = doc.root["items"][index: 0].int      // Int?

// 2. Codable, drop-in. Add @JSONCodable for a faster path the coders use automatically.
@JSONCodable
struct User: Codable { var id: Int; var name: String; var tags: [String] }
let users = try AemiJSON.JSONDecoder().decode([User].self, from: data)
let bytes = try AemiJSON.JSONEncoder().encode(users)

// 3. Off the main actor, in parallel across cores.
let rows = try await AemiJSON.decodeArrayConcurrently(Row.self, from: data)

// 4. Query — JSON Pointer (RFC 6901) and JSONPath (RFC 9535).
let title  = doc.root[pointer: "/store/book/0/title"].string
let titles = try doc.root.query("$.store.book[?(@.price < 10)].title")

// 5. Validate — JSON Schema (Draft 2020-12 subset)…
let schema = try JSONSchema(parsing: schemaText)
let result = schema.validate(data)               // .isValid / .errors

// …or generate one from a type at compile time with @Schemable (great for LLM tool / MCP schemas).
@Schemable(dialect: .draft7)
struct SearchInput: Decodable {
    /// Search terms.                             // doc comment → "description"
    var query: String
    @SchemaNumber(1...500) var limit: Int?        // → "minimum":1,"maximum":500
}
let toolSchema = SearchInput.jsonSchemaText      // draft-07 JSON, ready for tools/list

// 6. Mutate — JSON Patch (RFC 6902) / Merge Patch (RFC 7396).
let patched = try JSONPatch(patchData).apply(to: JSONValue(parsing: targetData))

// 7. Profiles — strict by default; opt into lenient or RFC 7493 I-JSON.
let lenient = try AemiJSON.parse(data, options: .lenient)
var decoder = AemiJSON.JSONDecoder(); decoder.options = .iJSON   // reject duplicate keys

// 8. Hot-path accessors — alloc-free compare, zero-copy bytes, JS-semantics, borrowed parse.
if doc.root.kind.utf8Equals("paragraph") { … }   // no String allocation on the unescaped path
buffer.withUnsafeBytes { raw in use(try AemiJSON.parse(raw).root) }   // zero-copy borrowed parse
let text = doc.root.tags.jsString                // ECMAScript coercion ("a,b,c"); also .isTruthy

// 9. Stream events from any async byte source (URLSession.AsyncBytes, FileHandle.AsyncBytes).
for try await event in JSONEventAsyncSequence(handle.bytes) { consume(event) }

// 10. Build values with literals or a result builder (control flow allowed).
let payload: JSONValue = ["id": 1, "tags": ["swift", "json"]]
let object  = JSONValue.makeObject {
    ("id", 1)
    if includeTags { ("tags", .makeArray { "swift"; "json" }) }
}
```

See the [documentation](#documentation) for the full guides.

## Performance

Apple M3 (macOS 26.5), release build, strict mode; treat these as ratios, not absolutes.
Reproduce with `AEMIJSON_DEV=1 swift package benchmark` (the [ordo-one/benchmark](https://github.com/ordo-one/benchmark)
suite under `Benchmarks/AemiJSONSuite`).

| Workload | AemiJSON vs Foundation |
|---|---|
| Untyped tape parse — `twitter.json` | **6.1×** `JSONSerialization` |
| Untyped tape parse — `citm_catalog.json` | **4.1×** |
| Untyped tape parse — `canada.json` (number-heavy) | **6.6×** |
| Codable decode — generic (`Data` → struct) | **1.8×** `JSONDecoder` |
| Codable decode — `@JSONCodable` fast path | **5.2×** `JSONDecoder` |
| Codable encode — `@JSONCodable` fast path | **7.6×** `JSONEncoder` |
| Codable encode — pretty (declaration order) | **≈1.2×** `JSONEncoder` |
| `[Double]` decode — number-heavy | **2.7×** `JSONDecoder` |
| Exact `Decimal` decode — short / long | **≈2.3× / 1.2×** `JSONDecoder` |
| Untyped parse — peak resident memory | **~5–9× lower** than `JSONSerialization` |

Tape parsing runs at roughly **1–1.5 GB/s** across the corpus (≈0.95 GB/s on number-heavy
`canada.json`); lazy access is faster still, since it skips subtrees it never reads. The flat tape
also holds peak memory flat (≈36 MB on the parse benchmark) where `JSONSerialization`'s object graph
balloons to hundreds of MB. Full untyped materialization into `JSONValue` edges just past
`JSONSerialization`. The remaining parity cases — untyped re-serialization, sorted encoding, and
ISO-8601 `Date` decoding — sit at parity, not ahead (pretty encoding streams in a single pass and
pulls slightly ahead). Methodology, the parity cases, and per-feature throughput: see the
**Benchmarking** guide.

## Standards

Strict by default. The grammar follows **RFC 8259** / **ECMA-404** / **ISO/IEC 21778:2017**
with **RFC 3629** UTF-8 well-formedness (overlongs, surrogates, and code points above U+10FFFF
rejected). Optional **RFC 7493 (I-JSON)** profile rejects duplicate keys. Query and mutation
follow **RFC 6901** (Pointer), **RFC 9535** (JSONPath — rejects 100% of the compliance suite's
invalid selectors and matches 99% of valid-query results; the remainder are I-Regexp `.`
line-separator edge cases), **RFC 6902** (Patch), **RFC 7396** (Merge Patch), and Relative JSON
Pointer. Schema targets **JSON Schema Draft 2020-12** (subset).

> **Numbers:** under the default `.swiftShortest`, a value typed `Double(2)` encodes as `2.0`
> through Codable, while `JSONValue` collapses it to `2` to keep integers round-tripping. Use
> the `.javaScript` profile for `JSON.stringify` parity. Details in the Encoding guide.

## Documentation

Full guides and the API reference ship as a **Swift DocC** catalog:

- **Getting Started**, **Parsing & Navigation**, **Codable Interop**, **Querying & Mutation**,
  **Schema Validation**, **Encoding & Numbers**, **Zero-Copy & JS-Semantics**
- **Async Streaming**, **JSON5 & Lenient Parsing**, and **swift-nio Interop** for streaming/server use
- **Architecture & Design Decisions**, **Depth Safety**, and **Benchmarking** for the how and why

The latest documentation is published to **<https://g-cqd.github.io/ADJSON/>** (built and
deployed by CI). Build it locally:

```sh
# Xcode: Product ▸ Build Documentation
# CLI (the DocC plugin is dev-only, gated behind AEMIJSON_DEV so consumers don't resolve it).
# Combined docs cover both the umbrella (AemiJSON) and the Foundation-free engine (AemiJSONCore):
AEMIJSON_DEV=1 swift package generate-documentation \
  --enable-experimental-combined-documentation --target AemiJSONCore --target AemiJSON
```

## Testing & benchmarks

Dev tasks run as SwiftPM plugins (no shell scripts). Conformance suites and the benchmark
corpus are third-party and fetched on demand:

```sh
swift package --allow-network-connections all --allow-writing-to-package-directory fetch-fixtures
swift test                                             # full conformance + unit suite
swift test --enable-code-coverage \
  && swift package coverage-check --floor 80           # coverage gate (Swift plugin)
AEMIJSON_DEV=1 swift package benchmark                   # benchmark suite (ordo-one/benchmark)
swift package bench-compare                            # AemiJSON-vs-Foundation table (reuses the suite binary)
swift package lint                                     # formatting gate + shipped-library discipline
swift package --allow-writing-to-package-directory format   # apply formatting
```

Without the fixtures, `swift test` still passes (corpus/conformance cases skip). See
[CONTRIBUTING.md](CONTRIBUTING.md) for the full developer workflow — git hooks, the `AEMIJSON_DEV`
flag, and build-time lint enforcement.

## License

MIT — see [LICENSE](LICENSE). Fetched fixtures (JSONTestSuite, JSONPath CTS, simdjson /
nativejson-benchmark corpus) remain under their respective upstream licenses and are not
redistributed in this repository.
