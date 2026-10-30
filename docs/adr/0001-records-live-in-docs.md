---
status: accepted
date: 2026-10-30
---

# 0001 — Decisions, plans, research and the diary live in `docs/`

## Context

AemiJSON had no written record of its decisions or plans: the reasons lived in commit messages and code comments. Its siblings keep them
in files with front matter (AemiRegex `docs/`, AemiProtobuf, analyzerkit `development/`), and the work coming from the swift-search
extraction (a JSON-RPC product, performance entries with numbers to keep) needs the same.

## Decision

`docs/adr/NNNN-title.md` (front matter `status`, `date`; sections Context, Decision, Evidence), `docs/roadmap/NNNN-title.md` (front matter
`status: not-started | in-progress | done | deferred`, `blocked-by`, `date`), `docs/research/<topic>-YYYY-MM-DD.md` with probes under
`docs/research/probes/` (kept as `.txt` so the lint does not read them), and `docs/diary/YYYY-MM-DD-NN.md`. AemiRegex's layout, so one
reader serves both.

## Evidence

The first entries: research `performance-and-correctness-2026-10-30.md`, roadmap 0001–0007.
