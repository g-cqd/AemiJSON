# Parsing and Navigation

Parse once, then navigate the lazy ``JSON`` view without materializing the whole document.

## Parsing

``ADJSON/parse(_:options:)-(Data,_)`` accepts `Data`, `[UInt8]`, or `String` and returns an immutable
``JSONDocument``. A `Data` input is retained as-is — no intermediate `[UInt8]` copy is made on
that hot path.

```swift
let doc = try ADJSON.parse(data)        // Data
let doc = try ADJSON.parse(bytes)       // [UInt8]
let doc = try ADJSON.parse(jsonString)  // String (UTF-8)
```

Parsing throws a typed ``JSONError`` on malformed or oversized input (empty input, trailing
data, bad UTF-8, depth/size limits, and — under the I-JSON profile — duplicate keys).

## The lazy `JSON` view

``JSONDocument/root`` returns a ``JSON`` — a lightweight cursor holding the document plus a
tape index. Navigation walks the tape; concrete Swift values are produced only when you read
a typed accessor.

### Dynamic member lookup and subscripts

```swift
let root = doc.root
root.user.name            // JSON (object member, via @dynamicMemberLookup)
root["user"]["name"]      // JSON (string-keyed subscript, same thing)
root.items[index: 0]      // JSON (array element)
```

Access is **`nil`-safe**: a missing key or out-of-range index yields a sentinel “missing”
``JSON`` (whose ``JSON/exists`` is `false`), so deep chains never trap.

```swift
doc.root.a.b.c.string     // nil if any link is absent — no crash
```

### Typed accessors

Optional accessors return `nil` on a type mismatch; the `…Value` variants supply a default.

```swift
let n: String? = node.string
let i: Int?    = node.int        // nil unless the number is an integer token
let d: Double? = node.double
let b: Bool?   = node.bool
let a: [JSON]? = node.array
let o: [String: JSON]? = node.object

let s  = node.stringValue        // "" if not a string
let cnt = node.count             // element count for arrays/objects, else 0
```

> Note: ``JSON/int`` succeeds only for an integer-shaped number token (no `.`/exponent).
> Use ``JSON/double`` for any JSON number, then convert if you need an integer.

### Presence and kind

```swift
node.exists      // false for a missing path
node.isNull
node.isObject
node.isArray
```

## When to materialize: `JSONValue`

The lazy ``JSON`` view is read-only. When you need an editable, fully-materialized tree —
for mutation, JSON Patch, or value equality — convert to ``JSONValue``:

```swift
let value = JSONValue(doc.root)         // from a lazy view
let value = try JSONValue(parsing: data) // straight from bytes
let data  = try value.encoded()          // back to compact UTF-8 JSON
```

``JSONValue`` stores numbers as `Double`; integers beyond 2^53 lose precision. See
<doc:EncodingAndNumbers> for how numbers are rendered on the way out.

## Lifetime & safety

A ``JSONDocument`` owns its input bytes and the tape for its whole lifetime, and it is
immutable and `Sendable`, so a parsed document can be shared freely across tasks and actors.
The lazy accessors borrow the underlying bytes only inside a scoped closure. See
<doc:Architecture> for the memory model.
