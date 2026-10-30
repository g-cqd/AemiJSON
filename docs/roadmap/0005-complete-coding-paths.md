---
status: not-started
blocked-by: []
date: 2026-10-30
---

# 0005 — Errors carry the coding path Foundation gives

Generic decode and encode errors lose their path (research `performance-and-correctness-2026-10-30.md`): `["n"]` for `["1", "p", "n"]`,
`[]` for `["0", "tags", "1"]`. Containers stay path-free on success; keyed and unkeyed decode and encode catch the error on the way out and
prepend their key or index, so the path costs only when there is an error. `codingPath` read from a decoder, encoder or container is
computed from a parent link. Drop the eager `codingPath + [key]` concatenations.

Red: the probe's four cases, plus a key-strategy case (the path carries the original key, as Foundation's does) and `superDecoder`, compared
with Foundation's `JSONDecoder`/`JSONEncoder` in a test. Bar: decode and encode p50 not worse.
