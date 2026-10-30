---
status: deferred
blocked-by: []
date: 2026-10-30
---

# 0001 — An allocation-count gate on the benchmarks

The suite measures mallocs but nothing fails when they grow: the `\u` escape regression (`f339174`) was found by a test written for it.
Keep `Benchmarks/Thresholds/` with the malloc counts of the deterministic benchmarks (parse, decode, encode, query, schema, stream), checked
with `swift package benchmark baseline check --check-absolute`, and record the counts each later entry changes.

Deferred with the rest of CI work; the counts are recorded by hand in the entries until then.
