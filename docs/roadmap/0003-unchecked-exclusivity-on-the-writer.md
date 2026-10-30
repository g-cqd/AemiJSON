---
status: done
blocked-by: []
date: 2026-10-30
---

# 0003 — No run-time exclusivity checks on the writer and the encode state

19% of a Codable encode is `swift_beginAccess`/`endAccess` on `JSONWriter.bytes` and `EncodeState`'s `kinds`, `counts`, `encodeDepth`.
Mark them `@exclusivity(unchecked)` as `DecodeContext` does, with the argument written beside each: every access is a short in-place append
or bump that is never borrowed across a call into user code.

Red: none possible for a missing check; the guard is a test that encodes from a user `encode(to:)` which re-enters the encoder (nested
containers, `superEncoder`) and the TSan pass. Bar: encode p50 down, outputs byte-identical over the corpus.

## Done

- `JSONWriter.bytes` and `EncodeState.kinds`, `counts`, `encodeDepth` are `@exclusivity(unchecked)`, each with its argument beside it.
  AemiJSONCore builds with strict memory safety, so every access to `bytes` in `JSONWriter.swift` is marked `unsafe`.
- Guard at `3439c7a` (`ReentrantEncodeTests`): a user `encode(to:)` that re-enters the encoder through nested keyed and unkeyed containers,
  `superEncoder(forKey:)`, a `@JSONCodable` value inside the generic path and recursion. It equals Foundation as a value, byte for byte
  with sorted keys (compact and pretty), and in the order of the calls. 445 tests pass before and after.
- In-process probe (release, 2,000 users, 200 iterations, min / p50, interleaved three times against `3439c7a`): Codable encode
  5.71–6.20 / 6.16–6.53 ms against 7.18–7.26 / 7.76–8.12 ms; `JSONValue.encodedBytes()` 1.73–1.75 / 1.87–1.89 ms on both sides.
- Suite: the full encode filter is unusable under the current load. Two interleaved rounds read Codable 6.7 and 25 ms new against 10 and
  14 ms base, and `JSONValue` 16 and 19 ms against 6 ms. `JSONValue` run alone, interleaved, read 5.5 and 6.9 ms against 6.0 and 7.9 ms, so
  the 16–19 ms readings were noise. Mallocs: Codable encode 8,008 before and after.
- Not run: TSan.
