# Parsing and Navigation

Parse once, then navigate the lazy ``/AemiJSONCore/JSON`` view without materializing the whole document.

## Parsing

``AemiJSON/parse(_:options:)-(Data,_)`` accepts `Data`, `[UInt8]`, or `String` and returns an immutable
``/AemiJSONCore/JSONDocument``. The `Data` overload copies the input once into the document's owned
buffer, which keeps repeated lazy reads on the fast inlined path; to parse a `Data` zero-copy
(borrowing its storage in place), pass it through the ``/AemiJSONCore/ByteSource`` overload instead.

```swift
let doc = try AemiJSON.parse(data)        // Data
let doc = try AemiJSON.parse(bytes)       // [UInt8]
let doc = try AemiJSON.parse(jsonString)  // String (UTF-8)
```

Parsing throws a typed ``/AemiJSONCore/JSONError`` on malformed or oversized input (empty input, trailing
data, bad UTF-8, depth/size limits, and — under the I-JSON profile — duplicate keys).

## The lazy `JSON` view

``/AemiJSONCore/JSONDocument/root`` returns a ``/AemiJSONCore/JSON`` — a lightweight cursor holding the document plus a
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
``/AemiJSONCore/JSON`` (whose ``/AemiJSONCore/JSON/exists`` is `false`), so deep chains never trap.

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

> Note: ``/AemiJSONCore/JSON/int`` succeeds only for an integer-shaped number token (no `.`/exponent).
> Use ``/AemiJSONCore/JSON/double`` for any JSON number, then convert if you need an integer.

### Presence and kind

```swift
node.exists      // false for a missing path
node.isNull
node.isObject
node.isArray
```

## When to materialize: `JSONValue`

The lazy ``/AemiJSONCore/JSON`` view is read-only. When you need an editable, fully-materialized tree —
for mutation, JSON Patch, or value equality — convert to ``/AemiJSONCore/JSONValue``:

```swift
let value = JSONValue(doc.root)         // from a lazy view
let value = try JSONValue(parsing: data) // straight from bytes
let data  = try value.encoded()          // back to compact UTF-8 JSON
```

``/AemiJSONCore/JSONValue`` stores numbers as `Double`; integers beyond 2^53 lose precision. See
<doc:EncodingAndNumbers> for how numbers are rendered on the way out.

### Constructing a value

Build a ``/AemiJSONCore/JSONValue`` from literals, or — when construction needs control flow — with the
``/AemiJSONCore/JSONValue/makeObject(_:)`` / ``/AemiJSONCore/JSONValue/makeArray(_:)`` result builders:

```swift
let literal: JSONValue = ["id": 1, "tags": ["swift", "json"], "ok": true]

let built = JSONValue.makeObject {
    ("id", 1)
    if includeTags { ("tags", .makeArray { for tag in tags { JSONValue.string(tag) } }) }
}
```

Scalars use the literal conformances (`42`, `"x"`, `true`); write `.null` for JSON null — the type
deliberately does **not** conform to `ExpressibleByNilLiteral`, so `nil` keeps meaning `Optional.none`
in your own code.

## Lifetime & safety

A ``/AemiJSONCore/JSONDocument`` owns its input bytes and the tape for its whole lifetime, and it is
immutable and `Sendable`, so a parsed document can be shared freely across tasks and actors.
The lazy accessors borrow the underlying bytes only inside a scoped closure. See
<doc:Architecture> for the memory model.
