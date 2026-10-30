---
status: done
blocked-by: []
date: 2026-10-30
---

# 0010 — The aemi and AemiRegex pins move together

AemiJSON pins aemi `04e49d1` and AemiRegex `923d23f` (`fdc0143`). AemiRegex has since moved its own aemi pin four times, to `2fbe4e4`
(`d5bac1c`), so that MacFS and the rest of the family resolve one aemi revision. SwiftPM accepts one revision per package identity: the
first time AemiJSON takes an AemiRegex newer than `923d23f`, its aemi pin must move to the one that AemiRegex pins, in the same commit, or
resolution fails.

Do: bump both pins in one commit, to AemiRegex's head and the aemi revision it names; rerun the suite, the analyzers and the probe
(`jprobe enc|val|dec|pretty`) against the previous pins, since aemi's kernels moved (CRC-32C, GuardedBytes, ADR 0020 and 0021) and
AemiJSONRPC now calls `AemiKernels.firstIndexOfByte`. Not now: nothing in AemiJSON needs the newer revisions yet.

## Done (2026-10-30)

Both pins moved in one commit: aemi `2fbe4e4`, AemiRegex `d5bac1c`, with AemiMarkdown (`6eaa031`), TerminalKit and ask following, so the
family resolves one revision. The suite passes (459, 44 and 2 tests, with `AD_TYPECHECK_BUDGET_MS=250`: `readsAPipeToItsEnd` takes 103 to
127 ms to type-check on this machine at the old pins as well). `AemiJSONProbe`, two runs before and after: retired instructions per
operation identical on twitter, citm_catalog and canada (within one million on canada's 180 M); thread CPU moved by up to ±20% between runs
on a machine shared with another build, so it is noise. The analyzers' findings (near-clones in `FastDecodeCursor.swift` and
`TapeDecoder.swift`) are on main before this change too; not addressed here.

