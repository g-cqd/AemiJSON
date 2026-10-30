---
status: not-started
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
