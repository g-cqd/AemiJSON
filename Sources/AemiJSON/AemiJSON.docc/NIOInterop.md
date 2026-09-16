# swift-nio Interop (AemiJSONNIO)

Parse and serialize JSON directly against swift-nio's `ByteBuffer`, with no copy on the read path.

## Overview

The `AemiJSONNIO` product bridges AemiJSON and swift-nio for server-side code. It is a **superset** of the
engine: it re-exports the Foundation-free `AemiJSONCore`, so `import AemiJSONNIO` brings `JSON`,
`JSONValue`, `AemiJSON.parse`, and the query / mutation API along with the NIO bridge — without pulling
in Foundation or swift-syntax.

swift-nio enters the dependency graph **only** through this product, which is gated behind the
`AEMIJSON_NIO` environment flag, so consumers of the base `AemiJSON` / `AemiJSONCore` products never resolve
it. Build or resolve with `AEMIJSON_NIO=1` and depend on the `AemiJSONNIO` product:

```swift
// Build/resolve with AEMIJSON_NIO=1, then:
.target(name: "MyServer", dependencies: [.product(name: "AemiJSONNIO", package: "ADJSON")])
```

## Zero-copy parsing

`AemiJSON.parse(_:)` accepts a `ByteBuffer` and parses its readable bytes **in place** — the document
borrows the buffer's storage instead of copying it, and the buffer's reader index is left unchanged.

```swift
import AemiJSONNIO

let doc = try AemiJSON.parse(buffer)        // borrows the buffer's storage; reader index unchanged
let id = doc.root.id.int
```

This is safe and `Sendable`. `ByteBuffer` is a copy-on-write value type, so the copy the document
retains keeps its bytes stable for the document's lifetime even if the caller later mutates theirs (a
write triggers a copy first). Only the readable region — from the reader index onward — is parsed.

## Writing into a ByteBuffer

`ByteBuffer.writeJSON(_:options:)` appends a value serialized to UTF-8 JSON and advances the writer
index. It accepts either a `JSONValue` or a lazy `JSON` cursor (the cursor form serializes straight
from the tape, with no `JSONValue` materialization), and takes the same `JSONEncodingOptions` as every
other encode path — compact by default, with opt-in pretty printing, sorted keys, number format, and
HTML-safe escaping.

```swift
var out = ByteBuffer()
try out.writeJSON(["ok": true, "id": .int(42)])                     // JSONValue via a literal
try out.writeJSON(doc.root, options: .init(keyOrder: .sorted))      // lazy cursor, sorted keys
```

## When to use it

Reach for `AemiJSONNIO` when you already hold a `ByteBuffer` — a NIO channel pipeline, an HTTP body —
and want to skip the `ByteBuffer` → `Data` / `[UInt8]` copy a Foundation round-trip would cost. For
non-NIO code, depend on `AemiJSON` or `AemiJSONCore` directly.
