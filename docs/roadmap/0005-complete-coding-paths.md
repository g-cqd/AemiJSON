---
status: done
blocked-by: []
date: 2026-10-30
---

# 0005 — Errors carry the coding path Foundation gives

Generic decode and encode errors lost their path (research `performance-and-correctness-2026-10-30.md`): `["n"]` for `["1", "p", "n"]`,
`[]` for `["0", "tags", "1"]`.

## Done

`CodingPaths.swift`. A decoder or encoder knows the path below the value it was made for. Each place that hands a value to a fresh one
catches the error on the way out and puts its own key or position in front. The places are:

- the keyed, unkeyed and single-value `decode<T>` and `encode<T>`;
- the primitive `Double`/`Float` encodes, which throw on a non-conforming float;
- the fast path's `fastArray`, `fastDictionary` and `decode`/`decodeIfPresent`/`decodeAt` fields.

On success, a path costs nothing. The prefix is an autoclosure on the encoder (`EncodeState.under(_:_:)`) and is built only in the `catch`.

Unkeyed containers add the element's position to the paths of their nested containers and `superDecoder`/`superEncoder`. A scalar
mismatch or an exhausted container reports the current position. A keyed `superEncoder()` adds `"super"`.

`TapeEncoder` stores its path. That makes it three words, which the existential still holds inline. The path is empty except under a
`superEncoder`.

`CodingPathTests` decodes and encodes 11 cases with both AemiJSON and Foundation and compares the paths:

- the probe's four cases;
- arrays of arrays;
- dictionaries;
- a key strategy: the path carries the type's key, `["1", "userName"]`, as Foundation's does;
- `superDecoder(forKey:)`;
- a nested keyed container;
- a nested unkeyed container holding a nested keyed one;
- an error the type throws itself, which comes out prefixed by the containers above it.

**Divergence, asserted explicitly.** Foundation's encoder drops a nested container's own key or position: `["a", "0", "x"]` and
`["b", "1"]`. AemiJSON keeps them, `["a", "0", "meta", "x"]` and `["b", "0", "1"]`, as Foundation's own decoder does.

**Measured.** The probe's in-process minimums against `9b3ed2d` were within 1–2% on both sides: decode 6.62–7.49 vs 6.56–7.43 ms,
encode 5.60–5.69 vs 5.50–6.29 ms. p50 values meant nothing at load average 117. 459 tests pass. Lint and analyzers are as at base.

## Not done

- **Absolute `codingPath` reads.** A type that reads `decoder.codingPath` or `encoder.codingPath` in its own `init(from:)` or
  `encode(to:)` still sees the path below the nearest generic `decode`/`encode`, usually `[]`. The errors are right; the property is not.
  Computing it from a parent link would cost a word and a retain per value on success. It waits for a consumer that reads it.
- **The macro readers' own errors.** See 0009.
