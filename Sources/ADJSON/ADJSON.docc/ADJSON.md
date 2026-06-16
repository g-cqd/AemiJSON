# ``ADJSON``

A fast, conformant, concurrency-safe JSON library for Swift 6 — a Codable-compatible,
drop-in alternative to Foundation's `JSONDecoder` / `JSONEncoder` / `JSONSerialization`,
plus JSON Schema, JSONPath, JSON Pointer, and JSON Patch.

## Overview

ADJSON scans input **once** into a compact `[UInt64]` **tape** — a flat, preorder
flattening of the document held in an immutable, `Sendable` ``/ADJSONCore/JSONDocument``. Swift values
are materialized **lazily**, only when you read them, so navigating a large payload to pull
out two fields never pays to decode the rest.

```swift
import ADJSON

// Lazy, dynamic access — nothing is materialized until you read it.
let doc = try ADJSON.parse(data)
let name = doc.root.user.name.string           // String?
let first = doc.root["items"][index: 0].int     // Int?

// Codable drop-in
let users = try ADJSON.JSONDecoder().decode([User].self, from: data)
let bytes = try ADJSON.JSONEncoder().encode(users)
```

Everything is value-typed and `Sendable`, parses off the main actor, and builds on the
Synchronization framework (`Atomic`, `Mutex`). The default profile is **strict**: the grammar
follows RFC 8259 / ECMA-404 / ISO/IEC 21778:2017 with RFC 3629 UTF-8 well-formedness, and it
passes the full nst/JSONTestSuite (318/318).

### Why ADJSON

- **Fast.** Tape parsing runs at roughly 1 GB/s; lazy access is faster still. See <doc:Benchmarking>.
- **Lazy.** ``/ADJSONCore/JSON`` is a cursor over the tape with `@dynamicMemberLookup`; missing paths
  return a sentinel instead of trapping, so `doc.root.a.b.c.string` is `nil`-safe.
- **Standards-first.** Strict by default, with opt-in profiles (lenient, RFC 7493 I-JSON).
- **Batteries included.** Schema (Draft 2020-12 subset), JSONPath (RFC 9535), Pointer
  (RFC 6901), Patch (RFC 6902), Merge Patch (RFC 7396), Relative Pointer.
- **Concurrency-safe.** Immutable documents; parallel array decode across cores.
- **Lean.** The engine ships as a separate, Foundation-free `ADJSONCore` product — no Foundation,
  no swift-syntax; its one dependency, `OrderedCollections`, is itself Foundation-free with no
  transitive deps — for consumers that want a minimal JSON core. See <doc:Architecture>.

## Topics

### Essentials

- <doc:GettingStarted>

### Guides

- <doc:ParsingAndNavigation>
- <doc:CodableInterop>
- <doc:Querying>
- <doc:SchemaValidation>
- <doc:EncodingAndNumbers>
- <doc:ZeroCopyAndJSSemantics>
- <doc:NIOInterop>

### Understanding ADJSON

- <doc:Architecture>
- <doc:Benchmarking>

### The engine (ADJSONCore)

The parsing, value, and query types — ``/ADJSONCore/JSON``, ``/ADJSONCore/JSONDocument``,
``/ADJSONCore/JSONValue``, ``/ADJSONCore/JSONParseOptions``, ``/ADJSONCore/JSONPath``,
``/ADJSONCore/JSONPointer``, ``/ADJSONCore/JSONPatch``, and the rest — live in the Foundation-free
engine and are re-exported here. Browse them in the ``ADJSONCore`` module reference.

### Codable

- ``/ADJSON/ADJSONCore/ADJSON/JSONDecoder``
- ``/ADJSON/ADJSONCore/ADJSON/JSONEncoder``
- ``JSONCodable()``

### Schema

- ``JSONSchema``
- ``ValidationResult``
- ``ValidationError``
- ``SchemaType``

### Schema generation

- ``Schemable(dialect:)``
- ``ADJSONSchemaProviding``
- ``SchemaDialect``
- ``SchemaScalarKind``
- ``SchemaNumber(minimum:maximum:exclusiveMinimum:exclusiveMaximum:multipleOf:type:)``
- ``SchemaNumber(_:multipleOf:type:)``
- ``SchemaString(minLength:maxLength:pattern:format:)``
- ``SchemaEnum(_:)``
- ``SchemaInfo(description:title:)``

### Streaming output

- ``JSONStreamWriter``
