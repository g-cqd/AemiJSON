# ADJSON

A fast, conformant, concurrency-safe JSON library for Swift 6.4 — a Codable-compatible,
drop-in alternative to Foundation's `JSONDecoder` / `JSONEncoder` / `JSONSerialization`,
plus JSON Schema, JSONPath, JSON Pointer, and JSON Patch.

Built on a single-pass **tape** scanner with an arena and **lazy, on-demand materialization**
(à la simdjson On-Demand / Foundation's `JSONMap`). Everything is value-typed and `Sendable`,
parses off the main actor, and uses the Synchronization framework (`Atomic`, `Mutex`).

## Highlights

- **Faster than Foundation**, measured on the standard corpus (Apple M2 Pro, release, strict mode):

  | Workload | ADJSON vs Foundation |
  |---|---|
  | Untyped parse — `twitter.json` | **5.7×** `JSONSerialization` |
  | Untyped parse — `citm_catalog.json` | **4.0×** |
  | Untyped parse — `canada.json` (number-heavy) | **8.0×** |
  | Codable decode (`Data` → struct) | **~2.8×** `JSONDecoder` |
  | Codable decode (`@JSONCodable` fast path) | **~4.2×** `JSONDecoder` |
  | Codable encode (`@JSONCodable` fast path) | **~3.4×** `JSONEncoder` |

  Tape parsing runs at roughly **1 GB/s**; partial/lazy access is faster still. The
  `@JSONCodable` fast path (a value-type encode buffer and an `@inlinable` cursor that
  inlines into your module) roughly doubled both Codable directions over the generic path.

- **Standards-conformant** (strict by default): the grammar follows **RFC 8259** /
  **ECMA-404** / **ISO/IEC 21778:2017**, with **RFC 3629** UTF-8 well-formedness (overlongs,
  surrogates, and >U+10FFFF rejected). Optional **RFC 7493 (I-JSON)** profile rejects duplicate
  keys. Query/mutation follow **RFC 6901** (Pointer), **RFC 9535** (JSONPath), **RFC 6902**
  (Patch), **RFC 7396** (Merge Patch), and Relative JSON Pointer. Schema targets **JSON Schema
  Draft 2020-12**. Passes the full **nst/JSONTestSuite (318/318)**.
- **Codable-compatible**: `ADJSON.JSONDecoder` / `ADJSON.JSONEncoder` mirror Foundation's API.
- **Lazy value** with `@dynamicMemberLookup`: `doc.root.user.name.string`.
- **JSON Schema** (Draft 2020-12 subset) validation, inference, and model generation.
- **Query**: JSON Pointer (RFC 6901), JSONPath (RFC 9535, ~88% of the compliance suite).
- **Mutation**: JSON Patch (RFC 6902), JSON Merge Patch (RFC 7396), Relative JSON Pointer.
- **Concurrency**: immutable `Sendable` documents; parallel array decode across cores.

## Requirements

- Swift 6.4+
- macOS 26 / iOS 26 / tvOS 26 / watchOS 26 / visionOS 26 or later
  (uses `Span`, `InlineArray`, and the Synchronization framework).

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/g-cqd/ADJSON.git", from: "0.1.0")
```

```swift
.target(name: "MyApp", dependencies: ["ADJSON"])
```

Reference the namespaced types as `ADJSON.JSONDecoder` etc. where Foundation is also imported.

## Usage

```swift
import ADJSON

// Lazy, dynamic access — nothing is materialized until you read it.
let doc = try ADJSON.parse(data)
let name = doc.root.user.name.string          // String?
let first = doc.root["items"][index: 0].int    // Int?

// Codable (drop-in)
let users = try ADJSON.JSONDecoder().decode([User].self, from: data)
let bytes = try ADJSON.JSONEncoder().encode(users)

// Opt-in fast path: @JSONCodable generates a monomorphic decode/encode that
// ADJSON.JSONDecoder/JSONEncoder use automatically (the type stays normal Codable).
@JSONCodable
struct User: Codable { var id: Int; var name: String; var tags: [String] }

// Strictness / profiles
let lenient = try ADJSON.parse(data, options: .lenient)
var decoder = ADJSON.JSONDecoder()
decoder.options = .iJSON                        // RFC 7493: reject duplicate keys

// Off the main actor, in parallel across cores
let rows = try await ADJSON.decodeArrayConcurrently(Row.self, from: data)

// JSON Schema (Draft 2020-12)
let schema = try JSONSchema(parsing: schemaText)
let result = schema.validate(data)              // .isValid / .errors
let inferred = JSONSchema.infer(from: samples)  // schema text from instances
let generated = JSONSchema.describe(myValue)    // schema text from a model

// Query
let pointed = doc.root[pointer: "/store/book/0/title"]            // RFC 6901
let titles = try doc.root.query("$.store.book[?(@.price < 10)].title")  // RFC 9535

// Mutation
let patched = try JSONPatch(patchData).apply(to: JSONValue(parsing: targetData))  // RFC 6902
let merged = JSONMergePatch.apply(patch, to: target)                              // RFC 7396
```

## Architecture

`parse` scans the input once into a compact `[UInt64]` **tape** (one slot per value;
containers store their element count and the index past their subtree for O(1) skips),
held in an immutable, `Sendable` `JSONDocument`. The lazy `JSON` view navigates the tape
and materializes Swift values only when accessed. The Codable decoder reads the tape with
byte-wise key matching (no eager dictionary, no per-node ARC); the encoder streams directly
into one buffer (no intermediate object tree).

## Testing & benchmarks

The conformance suites and benchmark corpus are third-party and fetched on demand:

```sh
scripts/fetch-fixtures.sh        # JSONTestSuite, JSONPath CTS, simdjson corpus
swift test                       # full conformance + unit suite
swift run -c release ADJSONBenchmarks
scripts/format.sh / scripts/lint.sh
```

Without the fixtures, `swift test` still passes (corpus/conformance cases skip).

## Safety & memory model

The scanner and the Codable decoder use `UnsafePointer` over the document's contiguous,
immutable storage for speed. The lifetime invariant — pointers are borrowed only inside a
`withBuffers`/`withBytePointer` scope, while the owning `JSONDocument` is retained for the
duration — is documented at each boundary, and the decode path bounds-checks every tape and
byte access under `assert` (so debug/test builds trap on any out-of-range index, while release
keeps raw-pointer speed). `Span`/`RawSpan` are not used on these paths because Codable's
`Decoder` must be `Escapable` (a `Span` cannot be stored in the shared decode context), and the
current toolchain's lifetime-dependence support is not yet able to thread spans through them.

## Roadmap

- `@JSONCodable` fast path: **landed**, including the throughput rework (a value-type encode
  buffer + an `@inlinable` cursor SPI that inlines the generated code into your module) — this
  roughly doubled both Codable directions. The remaining gap to the hand-rolled ceiling is the
  per-field key lookup; a single-pass positional decode codegen is the next step.
- `Span`/`RawSpan` adoption on the decode path: deferred until the toolchain's
  lifetime-dependence support matures (see Safety & memory model).

## License

MIT — see [LICENSE](LICENSE). Fetched fixtures (JSONTestSuite, JSONPath CTS, simdjson /
nativejson-benchmark corpus) remain under their respective upstream licenses and are not
redistributed in this repository.
