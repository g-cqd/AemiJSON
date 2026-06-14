# Codable Interop

Decode and encode your own types with a Foundation-compatible API — and opt into a faster
path when you want it.

## Drop-in coders

``ADJSON/JSONDecoder`` and ``ADJSON/JSONEncoder`` mirror Foundation's API surface.

```swift
struct User: Codable { var id: Int; var name: String; var tags: [String] }

let user  = try ADJSON.JSONDecoder().decode(User.self, from: data)
let bytes = try ADJSON.JSONEncoder().encode(user)
```

The decoder reads the tape directly: keyed lookups match `CodingKey` bytes against the tape
and skip unread subtrees in O(1) — no eager dictionary, no per-key `String` allocation, no
per-node reference-count churn. The encoder streams straight into one byte buffer with no
intermediate object tree.

### Decoding from an already-parsed document

If you already have a ``JSONDocument`` (e.g. from lazy inspection), decode from it directly to
skip re-scanning:

```swift
let doc = try ADJSON.parse(data)
if doc.root.kind.string == "user" {
    let user = try ADJSON.JSONDecoder().decode(User.self, from: doc)
}
```

### Options

The decoder exposes ``JSONParseOptions`` via its `options` property; the encoder exposes
``JSONEncodingOptions``. See <doc:EncodingAndNumbers>.

```swift
var decoder = ADJSON.JSONDecoder()
decoder.options = .iJSON                 // reject duplicate keys (RFC 7493)

var encoder = ADJSON.JSONEncoder()
encoder.options = .javaScript            // JSON.stringify number/non-finite parity
```

## The `@JSONCodable` fast path

Annotate a `Codable` `struct` with ``JSONCodable()`` to generate a monomorphic decode/encode
that ``ADJSON/JSONDecoder`` and ``ADJSON/JSONEncoder`` use **automatically**. The type keeps
its normal `Codable` conformance as a fallback.

```swift
@JSONCodable
struct User: Codable {
    var id: Int
    var name: String
    var tags: [String]
}

// Nothing else changes at the call site:
let users = try ADJSON.JSONDecoder().decode([User].self, from: data)
```

The generated code reads each field by its statically-known key directly off the tape (no
`KeyedDecodingContainer`, no per-field `String` key) and writes into a value-type buffer with
no class indirection. Built-in conformances make `[User]`, `User?`, and `[String: User]`
themselves fast, so a top-level array or a nested field skips Codable's collection machinery
too. Roughly doubles both directions over the generic path — see <doc:Benchmarking>.

### Scope and fallbacks

- Supports `struct`s whose stored properties have explicit type annotations.
- A type declaring custom `CodingKeys` is left on the generic path (a compile-time note
  explains why), so the fast path can't use the wrong keys.
- Anything not opted in still decodes/encodes through the standard generic path.

## Concurrent array decode

For a large top-level JSON array, scan once on the calling task and decode element batches in
parallel across cores, off the main actor:

```swift
let rows = try await ADJSON.decodeArrayConcurrently(Row.self, from: data)
```

Each worker binds its own pointer over the shared immutable document, so the work is data-race
free. `Row` must be `Decodable & Sendable`. The batch size is tunable
(`minimumBatch:`); below the threshold it decodes serially to avoid task overhead. See
<doc:Architecture> for the concurrency model.

## Process-wide metrics

``ADJSON/Metrics`` exposes lock-free counters (via `Atomic`) for documents and bytes parsed:

```swift
let m = ADJSON.Metrics.snapshot()
print(m.documents, m.bytes)
```
