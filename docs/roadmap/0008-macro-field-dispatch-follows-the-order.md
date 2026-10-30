---
status: not-started
blocked-by: []
date: 2026-10-30
---

# 0008 — `@JSONCodable` dispatch tries the next field first

The generated `__adjsonDecode` walks the object once and, for each member, tries the fields' keys in declaration order
(`if __k.matches("f0") … else if __k.matches("f1") …`): a document in declaration order costs k(k+1)/2 length-first comparisons. Generate a
dispatch that tries the field after the last one matched first, then the chain, without growing code size per field more than one
comparison. Measure with `KeyComparisonCounter` extended to `_FastKey.matches` (red: 12 fields in order ≤ 24 comparisons) and the
`@JSONCodable` decode benchmark.
