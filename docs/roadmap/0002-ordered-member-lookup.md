---
status: not-started
blocked-by: []
date: 2026-10-30
---

# 0002 — Member lookup that follows the document's order

`DecodeContext.memberValueIndex(of:key:)` scans an object from its first member for every key, O(k²) per object, 16% of a Codable decode.
Keyed containers remember where the last key was found and start the next scan there, wrapping once; with unique keys (the default) the
first hit is the answer. Duplicate-key policy and the snake_case path keep their meaning.

Red: a 64-key object decoded in order makes at most 2 × 64 key comparisons (a counting hook in debug), in reverse order still correct;
duplicate-key documents keep their last-wins / first-wins results. Bar: decode, AemiJSON Codable p50 down, mallocs unchanged.
