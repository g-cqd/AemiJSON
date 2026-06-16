# Zero-copy and JS-semantics accessors

Compare and read string nodes without allocating, render numbers the way JavaScript does, and
coerce values with ECMAScript semantics — for hosts bridging JSON to JavaScript behavior.

## Overview

The lazy ``/ADJSONCore/JSON`` view normally produces a Swift `String` when you read a string node. For hot
paths that only need to *compare* a field — "is this node named `type`?", "is the value
`paragraph`?" — that allocation is pure overhead. These accessors compare and borrow the raw tape
bytes directly, and add the JavaScript value coercions (`Boolean(x)`, `String(x)`) that content
pipelines bridging to JS semantics would otherwise re-implement.

## Alloc-free string comparison

``/ADJSONCore/JSON/utf8Equals(_:)`` compares a string node's value to a compile-time literal by UTF-8 bytes. On
the common unescaped path it allocates **nothing** — no `String`, no UTF-8 re-encode:

```swift
let node = doc.root.kind
if node.utf8Equals("paragraph") { … }     // no String allocation
```

It returns `false` for any non-string node, and is exactly equivalent to `node.string ==
literal.description` for string nodes. An *escaped* string (rare for literal-like values) is
decoded once before comparing, so the alloc-free guarantee holds only for unescaped nodes; the
literal may be any valid UTF-8, not just ASCII.

> Note: For short values that fit Swift's small-string buffer (≤ 15 UTF-8 bytes), `node.string ==`
> already avoids a heap allocation, so the win there is the skipped `String` construction and decode
> (~1.2× on the benchmark). For longer values, `utf8Equals` additionally eliminates a heap
> allocation per comparison.

## Zero-copy string bytes

``/ADJSONCore/JSON/withUTF8Bytes(_:)`` borrows the raw UTF-8 of an unescaped string node for the duration of a
closure, so you can append it straight into an output buffer without an intermediate `String`:

```swift
var out = [UInt8]()
let appended = node.withUTF8Bytes { out.append(contentsOf: $0) }   // Void? — nil if it didn't run
if appended == nil { out.append(contentsOf: Array((node.string ?? "").utf8)) }  // escaped fallback
```

It returns `nil` — and does **not** call the closure — for a non-string node or an escaped one
(whose stored bytes still carry escape sequences). Handle that case with ``/ADJSONCore/JSON/string``. The
pointer is valid only inside the closure; do not escape it.

## ECMAScript number strings

``/ADJSONCore/JSONOutput/ecmaNumberToString(_:)`` renders a `Double` exactly as JavaScript's `String(n)` /
`JSON.stringify(n)` — the ECMA-262 shortest-round-trip form. ``/ADJSONCore/JSON/jsNumberString`` applies it to
a number node:

```swift
JSONOutput.ecmaNumberToString(1e21)    // "1e+21"
JSONOutput.ecmaNumberToString(-0.0)    // "0"
JSONOutput.ecmaNumberToString(.nan)    // "NaN"   (a ToString token, not valid JSON)
doc.root.price.jsNumberString          // "9.99"  (nil for a non-number node)
```

Non-finite inputs render as the ECMAScript `ToString` tokens `"NaN"`, `"Infinity"`, and
`"-Infinity"`. Those are host coercions, **not** valid JSON — for serialization, the encoder routes
non-finite values through ``/ADJSONCore/JSONEncodingOptions`` instead.

## JavaScript truthiness

``/ADJSONCore/JSON/isTruthy`` is `Boolean(value)` — the `if (value)` test — over a JSON node:

| Falsy | Truthy |
|---|---|
| `false`, `null`, absent node | `true` |
| `0`, `-0`, `NaN` | every other number |
| `""` | every non-empty string (`"0"` and `"false"` are truthy!) |
| | **every** array and object, including `[]` and `{}` |

```swift
doc.root.flags.enabled.isTruthy        // false for 0/""/null/missing; true for [] and {}
```

## ECMAScript string coercion

``/ADJSONCore/JSON/jsString`` is the value's coercion to text following `Array.prototype.join`'s element rule —
which is what content renderers use to flatten a tree to a string:

```swift
doc.root.title.jsString                // "Hello"           (string → itself)
doc.root.count.jsString                // "42"              (number → ecmaNumberToString)
doc.root.tags.jsString                 // "a,b,c"           (array → join children with ",")
```

| Value | `jsString` |
|---|---|
| `null`, absent node | `""` |
| `true` / `false` | `"true"` / `"false"` |
| number | ``/ADJSONCore/JSONOutput/ecmaNumberToString(_:)`` |
| string | itself |
| object | `"[object Object]"` |
| array | elements coerced and joined with `","` (nested arrays flatten their separators) |

> Note: This mirrors `[x].join("")`, **not** standalone `String(x)`: `null` and `undefined` coerce
> to `""` (the join-element convention), where `String(null)` would be `"null"`. The implementation
> is iterative, so it handles arbitrarily deep arrays without recursion.

## Borrowed-buffer parsing

``/ADJSONCore/ADJSON/parse(_:options:)-(UnsafeRawBufferPointer,_)`` parses a caller-owned raw buffer with **no
copy**: the resulting ``/ADJSONCore/JSONDocument`` reads the bytes in place. This is the lowest-overhead entry
for an FFI payload or any buffer already held contiguously.

```swift
buffer.withUnsafeBytes { raw in
    let doc = try ADJSON.parse(raw)
    use(doc.root.items)        // read everything *inside* the borrow
}                              // do not let `doc` escape this scope
```

> Important: The buffer is **borrowed, not retained**. It must stay alive and unmodified for the
> entire lifetime of the returned document — every lazy ``/ADJSONCore/JSON`` read dereferences it. Using the
> document after the buffer is deallocated or mutated is undefined behavior. When the buffer cannot
> outlive the document, copy into `[UInt8]` and use the copying entry instead. Compared to that
> copy, the borrowed entry eliminates the input allocation (one fewer `malloc`, and the copy's
> wall-clock cost, which grows with input size).
