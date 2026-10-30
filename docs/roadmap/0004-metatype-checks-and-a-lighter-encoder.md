---
status: done
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

## Done

- `TapeEncoder` is a struct of two words (the `EncodeState` and a slot), so `any Encoder` holds it inline. The container it opened lives in
  `EncodeState.encoders`, a stack that `withEncoder` grows and truncates around each `encode(to:)`. A `superEncoder` slot lives until the
  enclosing value ends. Asking for the same container again returns it, and asking for a different one traps, as before.
- `encodeValue` compares `T.self` with `Date`, `Data` and `Decimal` before casting. The fast path asks
  `T.self as? any AemiJSONFastEncodable.Type` and opens the metatype, so a `@JSONCodable` value nested in a generic one is no longer boxed
  into an existential. The decoder already did both (`decodeGeneric`), so it needed no cache. No per-type cache was added either: the runtime
  caches conformance lookups, and the probe gave no reason to add one.
- The depth guard of `_JSONByteWriter.encode` and `encodeValue` is now `EncodingError.nestingTooDeep`, so the two no longer read as clones.
- Red at `16c8a6a` (`EncoderShapeTests`): the `Encoder` seen by `encode(to:)` was `class TapeEncoder`. Guards: a container asked for twice
  (keyed, unkeyed, single value) is the same container, and the custom date and data strategies still get a working encoder. 448 tests pass.
- Mallocs (benchmark suite, 2,000 users): Codable encode 8,008 → 4,009, and pretty encode 14,000 → 4,010. That is 2 per user: one
  `KeyedEncodingContainer` box for `User` and one for `Profile`. The standard library boxes every keyed container, and no encoder can avoid
  that. The bar was written as ≤ 4,000; the measured floor is two per keyed value plus 9.
- Probe (release, 200 iterations, three interleaved rounds against `86e5937`), min / p50:

  | Encode | New | Base |
  |---|---|---|
  | Codable | 5.05–5.47 / 5.59–6.46 ms | 5.87–6.19 / 7.09–7.39 ms |
  | Pretty | 6.62–6.65 / 7.71–7.91 ms | 7.82–7.91 / 9.06–9.40 ms |
  | Decode (unchanged path) | 6.04–6.07 / 6.85–7.27 ms | 6.06–6.09 / 7.07–7.73 ms |

  Suite, Codable encode p50: 6.6 and 13 ms new against 10 and 15 ms base, a wide spread under load.
- Under load, local `swift test` can break the 100 ms type-check budget on test files this change does not touch. `AD_TYPECHECK_BUDGET_MS=250`,
  the CI setting, passes.
