# JSON5 and Lenient Parsing

Opt into a relaxed grammar for human-authored or non-standard input — on every parse path.

## Overview

ADJSON is strict by default (RFC 8259). Two relaxed profiles loosen the grammar when you need them,
selected through ``JSONParseOptions``:

- ``JSONParseOptions/lenient`` — relaxes **string and number** validation: malformed escapes and
  UTF-8 pass through instead of being rejected, and the number grammar accepts a leading `+` and a
  bare leading/trailing decimal point (`+5`, `.5`, `5.`). It does **not** add JSON5 syntax.
- ``JSONParseOptions/json5`` — the full **JSON5** superset (json5.org): everything lenient relaxes,
  plus `//` line and `/* */` block comments, unquoted and single-quoted object keys, single-quoted
  strings, trailing commas, `Infinity` / `-Infinity` / `NaN`, hexadecimal integers (`0xFF`), and the
  JSON5 string escapes (`\x`, line continuations).

```swift
let doc = try ADJSON.parse(source, options: .json5)
```

```json5
{
  // a comment, then a trailing comma below
  unquoted: 'single-quoted value',
  hex: 0xFF,
  big: Infinity,
  list: [1, 2, 3,],
}
```

## One grammar, every path

The same relaxed grammar is honored everywhere, because the number / string / whitespace scanning is
a single shared tokenizer:

- the tape parser (`ADJSON.parse`)
- the pull SAX reader ``JSONEventReader`` and push reader ``JSONEventStreamReader``
- the async ``JSONEventAsyncSequence`` (see <doc:AsyncStreaming>)

In the streaming readers, JSON5 is fully resumable: a comment, string, or number split across a feed
boundary is held until the remaining bytes arrive.

## Strict vs lenient vs JSON5

| Feature | `.strict` | `.lenient` | `.json5` |
|---|:--:|:--:|:--:|
| RFC 8259 grammar | ✓ | ✓ | ✓ |
| Lenient string / escape validation | ✗ | ✓ | ✓ |
| Leading `+`, bare `.5` / `5.` | ✗ | ✓ | ✓ |
| `Infinity` / `NaN` / hex numbers | ✗ | ✗ | ✓ |
| Comments | ✗ | ✗ | ✓ |
| Unquoted / single-quoted keys | ✗ | ✗ | ✓ |
| Single-quoted strings, trailing commas | ✗ | ✗ | ✓ |

Use the strictest profile that accepts your input. For machine-to-machine JSON keep `.strict`, or
``JSONParseOptions/iJSON`` to additionally reject duplicate keys (RFC 7493).

## Topics

- ``JSONParseOptions``
