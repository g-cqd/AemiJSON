---
status: not-started
blocked-by: []
date: 2026-10-30
---

# 0009 — `@JSONCodable` readers report what Codable reports

0005 gives the fast path's errors their prefix. It leaves three errors in the `*At` readers that the generated `__adjsonDecode` calls,
each one different from what synthesized `Codable` throws on the same document:

1. **A type mismatch reports a missing key.** `stringAt`, `boolAt`, `doubleAt` and `integerAt` throw `keyNotFound` when the value is
   present but of the wrong type. Codable throws `typeMismatch` with the key in the path.
2. **`*IfPresentAt` swallows a wrong type.** `stringIfPresentAt`, `boolIfPresentAt`, `doubleIfPresentAt` and `integerIfPresentAt`
   return nil when the value is present and of the wrong type. Codable's `decodeIfPresent` throws `typeMismatch`.
3. **`decodeIfPresentAt` takes no key**, so its errors carry no field in their path.

Changing these changes the macro's generated calls. Readers that throw need a `key:` argument, and generated code from an older macro
must still compile. Add new entry points, keep the old ones as deprecated forwarders, and move the macro onto the new ones.

**Red:** for each reader, a `@JSONCodable` type and its `Codable` twin decode the same wrong-type document, and the two errors (case and
path) are compared.

**Bar:** `@JSONCodable` decode p50 not worse. Mismatches are checked only on the failure branch.
