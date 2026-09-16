# ``AemiJSON``

A fast, conformant, concurrency-safe JSON library for Swift 6 — a Codable-compatible,
drop-in alternative to Foundation's `JSONDecoder` / `JSONEncoder` / `JSONSerialization`,
plus JSON Schema, JSONPath, JSON Pointer, and JSON Patch.

## Overview

AemiJSON scans input **once** into a compact `[UInt64]` **tape** — a flat, preorder
flattening of the document held in an immutable, `Sendable` ``/AemiJSONCore/JSONDocument``. Swift values
are materialized **lazily**, only when you read them, so navigating a large payload to pull
out two fields never pays to decode the rest.

```swift
import AemiJSON

// Lazy, dynamic access — nothing is materialized until you read it.
let doc = try AemiJSON.parse(data)
let name = doc.root.user.name.string           // String?
let first = doc.root["items"][index: 0].int     // Int?

// Codable drop-in
let users = try AemiJSON.JSONDecoder().decode([User].self, from: data)
let bytes = try AemiJSON.JSONEncoder().encode(users)
```

Everything is value-typed and `Sendable`, parses off the main actor, and uses the Synchronization
framework (`Atomic` for process-wide metrics, `Mutex` for the encoder buffer pool). The default profile is **strict**: the grammar
follows RFC 8259 / ECMA-404 / ISO/IEC 21778:2017 with RFC 3629 UTF-8 well-formedness, and it
passes the full nst/JSONTestSuite (318/318).

### Why AemiJSON

- **Fast.** Tape parsing runs at roughly 1 GB/s; lazy access is faster still. See <doc:Benchmarking>.
- **Lazy.** ``/AemiJSONCore/JSON`` is a cursor over the tape with `@dynamicMemberLookup`; missing paths
  return a sentinel instead of trapping, so `doc.root.a.b.c.string` is `nil`-safe.
- **Standards-first.** Strict by default, with opt-in profiles (lenient, RFC 7493 I-JSON).
- **Batteries included.** Schema (Draft 2020-12 subset), JSONPath (RFC 9535), Pointer
  (RFC 6901), Patch (RFC 6902), Merge Patch (RFC 7396), Relative Pointer.
- **Concurrency-safe.** Immutable documents; parallel array decode across cores.
- **Lean.** The engine ships as a separate, Foundation-free `AemiJSONCore` product — no Foundation,
  no swift-syntax; its dependencies, `OrderedCollections` and `ADFCore`, are themselves
  Foundation-free with no transitive deps — for consumers that want a minimal JSON core. See <doc:Architecture>.

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

### Understanding AemiJSON

- <doc:Architecture>
- <doc:Benchmarking>
- <doc:DepthSafety>

### The engine (AemiJSONCore)

The parsing, value, and query types — ``/AemiJSONCore/JSON``, ``/AemiJSONCore/JSONDocument``,
``/AemiJSONCore/JSONValue``, ``/AemiJSONCore/JSONParseOptions``, ``/AemiJSONCore/JSONPath``,
``/AemiJSONCore/JSONPointer``, ``/AemiJSONCore/RelativeJSONPointer``, ``/AemiJSONCore/JSONPatch``, the
SQLite-dialect helpers (``/AemiJSONCore/SQLiteJSON``, ``/AemiJSONCore/SQLiteJSONPath``), and the rest —
live in the Foundation-free engine and are re-exported here. Browse them in the ``/AemiJSONCore``
module reference.

### Codable

- ``AemiJSON/JSONDecoder``
- ``AemiJSON/JSONEncoder``
- ``JSONCodable()``

### Schema

- ``JSONSchema``
- ``ValidationResult``
- ``ValidationError``
- ``SchemaType``

### Schema generation

- ``Schemable(dialect:)``
- ``AemiJSONSchemaProviding``
- ``SchemaDialect``
- ``SchemaScalarKind``
- ``SchemaNumber(minimum:maximum:exclusiveMinimum:exclusiveMaximum:multipleOf:type:)``
- ``SchemaNumber(_:multipleOf:type:)``
- ``SchemaString(minLength:maxLength:pattern:format:)``
- ``SchemaEnum(_:)``
- ``SchemaInfo(description:title:)``

### Streaming output

- ``JSONStreamWriter``
