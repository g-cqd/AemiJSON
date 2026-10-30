---
status: done
blocked-by: []
date: 2026-10-30
---

# 0002 — Member lookup that follows the document's order

`DecodeContext.memberValueIndex(of:key:)` scans an object from its first member for every key, O(k²) per object, 16% of a Codable decode.
Keyed containers remember where the last key was found and start the next scan there, wrapping once. The first hit is the answer only
when the object's keys are distinct, and the default parse (`.useLast`) does not know that: only `.throwError` marks a document's keys
unique. Duplicate-key policy and the snake_case path keep their meaning.

Red: a 64-key object decoded in order makes at most 2 × 64 key comparisons (a counting hook in debug), in reverse order still correct;
duplicate-key documents keep their last-wins / first-wins results. Bar: decode, AemiJSON Codable p50 down, mallocs unchanged.

## Done

- `MemberHints.swift`: a keyed container over an object of 4 or more members checks once that its keys are distinct (FNV-1a over the raw
  bytes, open addressing; an escaped key gives up, since two spellings can be one key; `.throwError` documents skip the check) and keeps a
  hint: the member to compare first and its ordinal. On a hit the hint stays on the member found, so `decodeIfPresent`'s
  `contains`-then-`decode` finds the key at once and the next key in order one comparison later. A duplicate key anywhere in the object,
  or an object under 4 members, keeps the full last-wins scan.
- The hints live in the context in `SIMD8<Int>` rings indexed by decode depth, and the key table in a `SIMD64<Int32>` for objects of up to
  32 members (a reused heap table past that), so no decode allocates more: an earlier draft with heap tables cost 2 mallocs per decode.
- Red at `43f4b21` (a debug-only `KeyComparisonCounter` bound through a task-local): 64 keys in order made 4,096 comparisons under the
  default options and 2,080 under `.throwError`; nested 5-key objects 75 for 15 keys. Green: at most 2k (2k − 1 exactly) in every case;
  duplicates (inline and heap tables, escaped spellings), reverse order, missing keys and the macro path unchanged. 441 tests pass.
- Benchmarks, release, interleaved with `43f4b21` in a worktree, on a machine at load average ~20 (spread is wide):
  decode, AemiJSON Codable p50 5,919 / 6,029 / 5,947 µs against 7,242 / 8,020 µs for the base in the same window (and 5,542–5,673 against
  6,197–6,730 µs in a quieter window, with the heap-table draft); `@JSONCodable` 2,331–2,341 against 2,515–2,550 µs (unchanged path,
  so that gap is the noise floor). Mallocs 8,271 before and after.
- Not changed: the macro path resolves fields in one walk with an if-chain per member, O(k × fields / 2) cheap comparisons in order; see 0008.
