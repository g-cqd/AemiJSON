# Getting Started

Install AemiJSON, parse your first document, and choose the access style that fits.

## Add the package

In `Package.swift`:

```swift
.package(url: "https://github.com/g-cqd/ADJSON.git", branch: "main")
```

```swift
.target(name: "MyApp", dependencies: ["AemiJSON"])
```

Where Foundation is also imported, reference the namespaced types explicitly —
``AemiJSON/JSONDecoder`` and ``AemiJSON/JSONEncoder`` — to avoid colliding with Foundation's
same-named types.

## Three ways to read JSON

AemiJSON gives you three access styles over the same single-pass tape. Pick by use case.

### 1. Lazy navigation (read a few fields)

Best when you want a handful of values out of a large payload. Nothing is decoded until
you ask for it.

```swift
let doc = try AemiJSON.parse(data)            // returns a JSONDocument
let name = doc.root.user.name.string         // String?
let age  = doc.root.user.age.int             // Int?
let tag0 = doc.root.tags[index: 0].string    // String?
```

See <doc:ParsingAndNavigation>.

### 2. Codable (map to your types)

A drop-in replacement for Foundation's coders.

```swift
struct User: Codable { var id: Int; var name: String; var tags: [String] }

let users = try AemiJSON.JSONDecoder().decode([User].self, from: data)
let bytes = try AemiJSON.JSONEncoder().encode(users)
```

For a higher-throughput path, annotate the type with ``JSONCodable()``. It keeps standard
`Codable` and adds a monomorphic fast path the coders use automatically. See
<doc:CodableInterop>.

### 3. Mutable value tree (edit, patch)

``/AemiJSONCore/JSONValue`` is the fully-materialized, editable counterpart used by JSON Patch and Merge
Patch.

```swift
var value = try JSONValue(parsing: data)
let patched = try JSONPatch(patchData).apply(to: value)
```

See <doc:Querying>.

## Strictness & profiles

The default is RFC 8259 strict. Override per call or per coder via ``/AemiJSONCore/JSONParseOptions``.

```swift
let lenient = try AemiJSON.parse(data, options: .lenient)   // permissive scanning

var decoder = AemiJSON.JSONDecoder()
decoder.options = .iJSON                                    // RFC 7493: reject duplicate keys
```

## Requirements

- Swift 6.3+ toolchain (language mode v6; built and tested on 6.3).
- macOS 15+ / iOS 18+ / tvOS 18+ / watchOS 11+ / visionOS 2+ (the floor is set by the
  Synchronization framework's `Atomic`/`Mutex`).

## Next steps

- <doc:ParsingAndNavigation> — the lazy ``/AemiJSONCore/JSON`` view in depth.
- <doc:CodableInterop> — Codable, the `@JSONCodable` fast path, and concurrent decode.
- <doc:Querying> — Pointer, Path, Patch, Merge Patch.
- <doc:Architecture> — how the tape works and why.
