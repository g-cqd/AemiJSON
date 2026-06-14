# Encoding and Number Formatting

Control serialization with profiles, and understand exactly how numbers are rendered.

## Encoding profiles

``JSONEncodingOptions`` controls serialization. Two presets cover the common cases:

- ``JSONEncodingOptions/rfc8259`` (default) — strict RFC 8259 / ECMA-404: reject non-finite
  numbers, shortest numbers, declaration order.
- ``JSONEncodingOptions/javaScript`` — byte-for-byte JavaScript `JSON.stringify`: non-finite
  → `null`, ECMA-262 number formatting.

```swift
var encoder = ADJSON.JSONEncoder()
encoder.options = .javaScript

let data = try JSONValue(parsing: input).encoded(options: .javaScript)
```

Knobs: `nonFinite` (throw / `null` / string literals), `numberFormat` (`.swiftShortest` /
`.ecma262`), `keyOrder` (`.declaration` / `.sorted`), `escapeSlashes`, and `nilStrategy`
(`.omit` / `.null`).

> Note: `keyOrder` and `nilStrategy` are honored by ``JSONValue/encoded(options:)`` and
> ``JSONStreamWriter``, not by the streaming Codable path (which emits in the encoder's call
> order and omits `nil` optionals, matching Foundation).

## How numbers are rendered

This is the one place ADJSON's behavior is worth reading carefully, because three paths make
three deliberate choices under the default `.swiftShortest` format:

| Path | Input | Output | Why |
|---|---|---|---|
| Codable encoder | `Double(2)` | `2.0` | The static type is `Double`; render it faithfully. |
| ``JSONValue`` | `.number(2)` | `2` | The value model stores only `Double`; collapsing integral magnitudes lets a JSON integer round-trip unchanged. |
| Foundation (for reference) | `Double(2)` | `2` | Foundation collapses integral doubles. |

In other words:

- A value **typed `Double`** through the Codable encoder keeps its fractional form (`2.0`),
  because the type says it is a floating-point value.
- A ``JSONValue/number(_:)`` collapses an integral magnitude (below 2^53) to integer form
  (`2`), so parsing `2` and re-encoding yields `2` again — important for JSON Patch/Merge
  round-trips where the model has no separate integer case.

Neither default path reproduces Foundation's float formatter **byte-for-byte** across the full
range (the exponent thresholds differ — e.g. Foundation prints `1e15` as `1000000000000000`
but `1e16` as `1e+16`). When you need `JSON.stringify` parity, use the `.ecma262` number
format (the `.javaScript` profile):

```swift
JSONValue.number(5.0).encoded(options: .javaScript)   // "5"
JSONValue.number(1e-7).encoded(options: .javaScript)  // "1e-7"
```

## Non-finite numbers

JSON cannot represent `NaN` or `±Infinity`. Under `.rfc8259` these throw
`EncodingError.invalidValue`; under `.javaScript` they become `null`; or emit custom string
literals via `nonFinite: .stringLiterals(...)`.

## Streaming output

For event-driven emission (e.g. straight into a network buffer), ``JSONStreamWriter`` is a
`~Copyable`, value-type writer whose default output matches `JSON.stringify`. It auto-inserts
separators so call sequences can't desync, and `finish()` moves the buffer out with no copy.

```swift
var w = JSONStreamWriter()
w.beginObject()
w.key("id"); w.integer(1)
w.key("name"); w.string("ada")
w.endObject()
let bytes = w.finish()
```

It also offers verbatim splice helpers (`raw`, `rawOrNull`, `rawValidated`) for embedding
pre-rendered fragments — `rawValidated` checks well-formedness via the parser first.
