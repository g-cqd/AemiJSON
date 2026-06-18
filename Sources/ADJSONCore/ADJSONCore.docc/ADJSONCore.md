# ``ADJSONCore``

The Foundation-free, swift-syntax-free engine behind ADJSON: single-pass tape parsing, lazy
navigation, the eager `JSONValue` tree, and JSONPath / Pointer / Patch.

## Overview

`ADJSONCore` is the lean core of the library — tape parsing, the lazy ``JSON`` cursor over a
``JSONDocument``, the materialized ``JSONValue``, query and mutation (JSONPath, Pointer, Patch,
Merge Patch), and the low-level byte helpers the encoders share. Its dependencies,
`OrderedCollections` and `ADFCore` (ADFoundation's shared byte/number primitives), are themselves
Foundation-free with no transitive dependencies, so the core stays portable and dependency-strict.

The umbrella ``ADJSON`` module re-exports everything here (`import ADJSON` sees the full core) and
adds Foundation interop, Codable (`JSONEncoder` / `JSONDecoder`), JSON Schema, and the macros. Depend
on the `ADJSONCore` product when you want only the engine.

```swift
import ADJSONCore

let doc = try ADJSON.parse(bytes)              // [UInt8], String, ByteSource, or a borrowed buffer
let name = doc.root.user.name.string           // String? — lazy, nil-safe
let value = JSONValue(doc.root)                // materialize when you need an editable tree
```

## Topics

### Guides

- <doc:AsyncStreaming>
- <doc:JSON5AndLenient>

### Parsing & navigation

- ``ADJSON``
- ``JSONDocument``
- ``JSON``
- ``ByteSource``

### Values & options

- ``JSONValue``
- ``JSONParseOptions``
- ``JSONEncodingOptions``
- ``JSONError``

### Query & mutation

- ``JSONPath``
- ``JSONPointer``
- ``RelativeJSONPointer``
- ``JSONPatch``
- ``JSONMergePatch``
- ``JSONPathError``
- ``JSONPointerError``
- ``JSONPatchError``

### Streaming events

- ``JSONEvent``
- ``JSONEventReader``
- ``JSONEventStreamReader``
- ``JSONEventAsyncSequence``
- ``JSONEachSequence``
- ``JSONTreeSequence``

### Low-level byte helpers

- ``JSONOutput``
- ``JSONString``
- ``JSONNumber``
- ``JSONKey``
- ``Slot``
- ``JSONKind``

### SQLite-dialect JSON

- ``SQLiteJSON``
- ``SQLiteJSONPath``
- ``SQLiteJSONRow``
- ``SQLiteJSONPathError``
