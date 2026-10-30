---
status: not-started
blocked-by: []
date: 2026-10-30
---

# 0004 — Metatype checks before casts, and an encoder that is not a class per value

- `EncodeState.encodeValue` compares `T.self` with `Date.self`, `Data.self`, `Decimal.self` before casting, as `decodeGeneric` does, and asks
  the fast-path conformance once per type (a small cache keyed by `ObjectIdentifier(T.self)`), not per value. The decoder's
  `T.self as? any AemiJSONFastDecodable.Type` gets the same cache.
- `TapeEncoder` (a class allocated per nested value, ~4 mallocs a user) keeps its container state in `EncodeState`'s frame stack, so the
  `Encoder` handed to `encode(to:)` is a small reference into it, or at worst one allocation.

Red: malloc count of encode, AemiJSON Codable over the 2,000 users ≤ 4,000 (from 8,008), in a test that counts with the suite's hook; the
date, data and decimal strategies unchanged. Bar: encode and decode p50 down.
