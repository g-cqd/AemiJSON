---
status: not-started
blocked-by: []
date: 2026-10-30
---

# 0003 — No run-time exclusivity checks on the writer and the encode state

19% of a Codable encode is `swift_beginAccess`/`endAccess` on `JSONWriter.bytes` and `EncodeState`'s `kinds`, `counts`, `encodeDepth`.
Mark them `@exclusivity(unchecked)` as `DecodeContext` does, with the argument written beside each: every access is a short in-place append
or bump that is never borrowed across a call into user code.

Red: none possible for a missing check; the guard is a test that encodes from a user `encode(to:)` which re-enters the encoder (nested
containers, `superEncoder`) and the TSan pass. Bar: encode p50 down, outputs byte-identical over the corpus.
