# Deterministic-first frontier — four directions, researched

**Date:** 2026-06-28
**Frames:** `docs/deterministic-first-frontier.md` (the principle + layers).
**Raw research:** `.superpowers/research/{quiet-patch-design,dfirst-auditor-design,orchestration-feasibility}.md`.

Four directions were researched. Outcome: build two, document two.

## 1. Output side — `quiet-patch` / `quiet-applies` → BUILD (scoped)

Output tokens are ~3–5× priced and serial, so this is the biggest *untapped* layer.
**Honest scope:** the agent's native **Edit** tool already sends change-sized edits,
so quiet-patch is a *complement*, not a replacement. Genuine non-overlapping value:
1. applying an **existing diff blob** (from another model / `gh pr diff` / a review tool) — Edit can't consume a diff;
2. **atomic multi-file** patches — Edit applies per-file (partial-apply hazard); `git apply` is all-or-nothing;
3. **no-Edit contexts** (plain bash / CI / subagents);
4. **`quiet-applies`** (`git apply --check`) — a pre-check with *no Edit equivalent*; highest-confidence, zero-overlap piece.

Safety: check-before-apply + git atomicity + refuse `--reject`/`--whitespace=fix`
→ a bad diff fails loud, never corrupts the tree. Interfaces:
- `quiet-patch.sh [-R] [-p N] [--root DIR] [-f patch.diff] < diff` → dry-run then
  apply; `[quiet-patch] OK — applied N file(s), +A −D` / `FAIL … no changes written`; exit 0/1/2.
- `quiet-applies.sh [...] < diff` → read-only check; `APPLIES` / `CONFLICT` + git's
  `file:line`; exit 0/1/2.
Skill nudge hands single small edits *back to Edit*; reach for quiet-patch only on
cases 1–3, and always `quiet-applies` before reasoning about whether a patch fits.

## 2. Meta — deterministic-first auditor → BUILD

Mines transcripts to surface where the model did tool-shaped work → finds future
candidates automatically. Extends `bench/session-savings.py` (same discovery/parse)
with a sequence model over consecutive tool calls.

| Pattern (JSON signal) | Lever | Confidence |
|---|---|---|
| re-Read same path, no Edit between, identical bytes | dedup | **High** |
| ≥2 `node -v`/`which X` version probes | quiet-env | **High** |
| large result → short pass/fail/count text | quiet-check | Med-High |
| ≥3 sibling-dir Reads → answer | rg/quiet-map | Med |
| list output → prose count | quiet-agg | Med |
| Write of pre-existing file ≈ prior Read size | quiet-patch | Med |
| big config Read → quote one value | quiet-conf | Low — **drop v1** |

Ships as `bench/dfirst-audit.py` (on-demand, like session-savings.py). Reliable
tier headlined; inferential tier gated behind `--min-confidence` and labelled
directional. **Actionable output = new-candidate discovery**, not a savings number
(absolute token figures are vanity; keep billing in `bench/run.sh` +
`session-savings.py`). Tested with `tests/fixtures/transcripts/*.jsonl` (no
`~/.claude` access in CI).

## 3. Orchestration → DOCUMENT (mostly unreachable)

| Candidate | Verdict | Why |
|---|---|---|
| Model routing | **NEEDS-HARNESS** | a PreToolUse(Task) hook can't set the subagent model — this is why `model-economy` arm B was never wired; the blunt `CLAUDE_CODE_SUBAGENT_MODEL` proxy measured DO-NOT-SHIP-leaning (+38.7%, Haiku took more turns) |
| `quiet-cache` (result memoization) | **BUILDABLE (opt-in verb only)** | transparent hook short-circuit impossible; an explicit verb keyed on cmd+cwd+mtimes + TTL + visible `cached @` banner is reachable — its own future project, below quiet-patch, staleness-gated |
| Stop conditions | **DROP** | Stop/SubagentStop hooks are wrong-polarity (can block stopping, can't safely end early) |
| Retry/backoff | **DROP** | no hook re-runs a tool; re-running non-idempotent commands is a footgun |

Net: only `quiet-cache` is buildable, and it's deferred. The rest is out of
quiet-bash's hook/skill/CLI surface — documented so we stop re-proposing it.

## 4. The principle write-up → DONE

`docs/deterministic-first-frontier.md` — the reusable lens, layers, invariant,
decision rule, and ranked open frontier.

---

## This-round build plan
Spec → plan → subagent build for **quiet-patch + quiet-applies + dfirst-audit**
(+ skill/README surface). Orchestration ships as this research doc; `quiet-cache`
queued as a future standalone project.
