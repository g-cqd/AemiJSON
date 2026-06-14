# Getting Started

Install ADJSON, parse your first document, and choose the access style that fits.

## Add the package

In `Package.swift`:

```swift
.package(url: "https://github.com/g-cqd/ADJSON.git", from: "0.1.0")
```

```swift
.target(name: "MyApp", dependencies: ["ADJSON"])
```

Where Foundation is also imported, reference the namespaced types explicitly —
``ADJSON/JSONDecoder`` and ``ADJSON/JSONEncoder`` — to avoid colliding with Foundation's
same-named types.

## Three ways to read JSON

ADJSON gives you three access styles over the same single-pass tape. Pick by use case.

### 1. Lazy navigation (read a few fields)

Best when you want a handful of values out of a large payload. Nothing is decoded until
you ask for it.

```swift
let doc = try ADJSON.parse(data)            // returns a JSONDocument
let name = doc.root.user.name.string         // String?
let age  = doc.root.user.age.int             // Int?
let tag0 = doc.root.tags[index: 0].string    // String?
```

See <doc:ParsingAndNavigation>.

### 2. Codable (map to your types)

A drop-in replacement for Foundation's coders.

```swift
struct User: Codable { var id: Int; var name: String; var tags: [String] }

let users = try ADJSON.JSONDecoder().decode([User].self, from: data)
let bytes = try ADJSON.JSONEncoder().encode(users)
```

For a higher-throughput path, annotate the type with ``JSONCodable()``. It keeps standard
`Codable` and adds a monomorphic fast path the coders use automatically. See
<doc:CodableInterop>.

### 3. Mutable value tree (edit, patch)

``JSONValue`` is the fully-materialized, editable counterpart used by JSON Patch and Merge
Patch.

```swift
var value = try JSONValue(parsing: data)
let patched = try JSONPatch(patchData).apply(to: value)
```

See <doc:Querying>.

## Strictness & profiles

The default is RFC 8259 strict. Override per call or per coder via ``JSONParseOptions``.

```swift
let lenient = try ADJSON.parse(data, options: .lenient)   // permissive scanning

var decoder = ADJSON.JSONDecoder()
decoder.options = .iJSON                                    // RFC 7493: reject duplicate keys
```

## Requirements

- Swift 6.3+ toolchain (language mode v6; developed and tested on 6.4).
- macOS 15+ / iOS 26 / tvOS 26 / watchOS 26 / visionOS 26 or later.

## Next steps

- <doc:ParsingAndNavigation> — the lazy ``JSON`` view in depth.
- <doc:CodableInterop> — Codable, the `@JSONCodable` fast path, and concurrent decode.
- <doc:Querying> — Pointer, Path, Patch, Merge Patch.
- <doc:Architecture> — how the tape works and why.
