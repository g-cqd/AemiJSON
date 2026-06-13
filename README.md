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
  | Codable decode (`Data` → struct) | **~2.7×** `JSONDecoder` |
  | Codable encode (struct → `Data`) | **~1.7×** `JSONEncoder` |

  Tape parsing runs at roughly **1 GB/s**; partial/lazy access is faster still.

- **RFC-conformant** (strict by default): RFC 8259 / ECMA-404 / ISO-IEC 21778, RFC 3629 UTF-8.
  Passes the full **nst/JSONTestSuite (318/318)**.
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

## Roadmap

- `@JSONCodable` macro for monomorphic, one-pass decode/encode targeting maximum
  server-side throughput (the generic paths already beat Foundation today).

## License

MIT — see [LICENSE](LICENSE). Fetched fixtures (JSONTestSuite, JSONPath CTS, simdjson /
nativejson-benchmark corpus) remain under their respective upstream licenses and are not
redistributed in this repository.
