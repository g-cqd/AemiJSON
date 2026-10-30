# Performance and correctness review — 2026-10-30

What the AemiProtobuf work taught (profile before changing, exclusivity checks and casts dominate generic Codable paths, compare against
Foundation byte for byte), applied to AemiJSON at `fdc0143`. Release, Apple silicon, a loaded machine; the ordo-one suite
(`AEMIJSON_DEV=1 swift package benchmark`) gives p50 and mallocs, the profiles come from `sample` over an `-Ounchecked` probe that decodes and
encodes the suite's 2,000 users.

## Where the time goes

| Benchmark | p50 | mallocs |
|---|---:|---:|
| decode, AemiJSON Codable | 6.20 ms | 8,271 |
| decode, `@JSONCodable` | 2.33 ms | 4,259 |
| decode, Foundation | 11 ms | 32 K |
| decode, snake_case | 8.24 ms | 16 K |
| encode, AemiJSON Codable | 7.40 ms | 8,008 |
| encode, `@JSONCodable` | 1.29 ms | 2,002 |
| encode, Foundation | 10 ms | 23 K |
| parse, tape | 856 µs | 4 |
| parse, full walk | 3.40 ms | 8,259 |
| query, filter | 490 µs | 4,040 |
| schema, validate | 4.46 ms | 1,606 |
| stream, events | 2.20 ms | 2,670 |
| encode, ECMAScript number | 41 ms | 398 K |

The tape is 4–6× faster than `JSONSerialization`; Codable decoding is 1.8× and encoding 1.4× faster than Foundation's. The macro path is
2.7× and 5.7× faster than the generic one, which says how much the generic path leaves.

**Decode** (top of stack, samples): `DecodeContext.memberValueIndex(of:key:)` 391 of ~2,400 (16%), bridge-object retain/release ~15%, the
conformance check `T.self as? any AemiJSONFastDecodable.Type` with its metadata lookups (`swift_conformsToProtocol…`, `getCache`) ~8%.
`memberValueIndex` scans the object's members from the first for every key: O(k²) for an object of k keys, though `Decodable` asks for
them in declaration order, which is usually the document's order.

**Encode:** `swift_beginAccess`/`endAccess` 431 of ~2,200 (19%), the run-time exclusivity checks on `JSONWriter.bytes` (a class property,
written for every byte run) and on `EncodeState`'s `kinds`, `counts` and `encodeDepth`. `DecodeContext` already exempts its hot fields with
`@exclusivity(unchecked)`. `tryCast` 111 (5%): `encodeValue` tries `as? Date`, `as? Data`, `as? Decimal` and `as? any AemiJSONFastEncodable`
on every value, where `decodeGeneric` compares metatypes first. `TapeEncoder` is a class allocated per nested value: about 4 mallocs a user.

**ECMAScript numbers** allocate one `String` per double (398 K mallocs for 200 K doubles).

## A correctness defect: coding paths are lost

Errors from the generic path carry the wrong `codingPath` (probe `probes/coding-path.swift.txt`):

| Case | Foundation | AemiJSON |
|---|---|---|
| `"n": "x"` in the second user's profile | `["1", "p", "n"]` | `["n"]` |
| `"y"` in the first user's tags | `["0", "tags", "1"]` | `[]` |
| profile without `n` | `["0", "p"]` | `[]` |
| encoding NaN | `["0", "v"]` | `[]` |

`decodeGeneric` builds every `TapeDecoder` with `codingPath: []`, and every encoder container answers `[]`. Meanwhile `nestedContainer` pays
for `codingPath + [key]` on every nested container, so the path costs without being right. No test checks a coding path.

The fix that costs nothing on success: keep containers path-free and rebuild the path while the error unwinds. Each keyed or unkeyed decode
and encode catches `DecodingError` / `EncodingError`, prepends its key or index to the context's path, and rethrows. A `superDecoder` or a
user's `codingPath` read gets the true path computed on demand from a parent link.

## What swift-search needs from here

swift-search frames JSON-RPC for sourcekit-lsp (Content-Length) and for MCP (newline-delimited) in its own `LSPFrame`, `LSPFrameDecoder`,
`LanguageServerConnection` and `MCPStdio`; arcleak (`LspServer.swift`), ask (`AskMCP`: `LineSplitter`, `StdioTransport`, `MCPWire`) and
Atelier (`AtelierLSP/JSONRPC.swift`) each have another. The header scan is byte-by-byte and stdin is read one byte per call (swift-search
H8). One product beside AemiJSON, over `AemiKernels.firstIndexOfByte`, serves all four (analyzerkit P3).
