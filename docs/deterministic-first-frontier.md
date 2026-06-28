# The deterministic-first lens — principle, layers, frontier

A reusable framework behind every quiet-bash lever. Use it to decide what to build
next and to keep new work inside the no-regression boundary.

## The principle

> **Any time the model spends tokens doing something a deterministic process could
> do better, cheaper, or more reliably — shift that work to the harness.**

The model is the expensive, non-deterministic, serial component. A shell pipeline,
a hook, or a cached lookup is cheap, exact, and parallelizable. Most "agent cost"
is the model doing work a deterministic tool would do for ~free.

## The invariant (the boundary that makes it safe)

Every shift must be **mechanical, lossless-or-byte-exact-recoverable, no extra LLM
call, no regression, zero-dependency.** The dividing line discovered repeatedly:

- **Safe to do deterministically:** compress/recover output, compute an answer,
  detect an unchanged re-read, return a ground-truth verdict — anything where the
  deterministic result is *provably equivalent* or *strictly recoverable*.
- **Safe only to *encourage*, never to *force*:** changing the model's *choice*
  (a skill nudge), because forcing it (rewriting a Read into a grep) can silently
  drop information the model needed → regression.
- **Out of reach / deferred:** anything that edits prior turns (busts prompt
  cache), needs a non-bundled binary, or makes a completeness claim a tool can't
  honor (a symbol index that misses a def is worse than a search).

## The layers (and what's shipped)

| Layer | The model does… | Deterministic shift | Status |
|---|---|---|---|
| **Input — output compression** | re-reads bulky command/file/tool output every turn | spill byte-exact, leave a summary | ✅ shipped (core hooks, quiet-query) |
| **Input — find/compute** | reads a haystack to find/count/extract/parse/verify | shell pipeline returns the answer | ✅ shipped (deterministic-first skill, quiet-verify/agg/check) |
| **Input — repeated/blocking** | re-reads unchanged files, re-judges logs, polls | dedup, verdict+tally, one-shot wait | ✅ shipped (dedup, quiet-check, quiet-wait) |
| **Input — lookup/orient** | reads whole configs, scrolls git logs, explores, probes toolchain | one value / archaeology / folder+env map | ✅ shipped (quiet-conf/hist/blame, quiet-map, quiet-env) |
| **Output — generation** | re-emits whole files; formats/scaffolds by hand | emit a *diff* (`git apply`); run a formatter; template | ◻ open — **`quiet-patch`/`quiet-applies`** (highest remaining lever; output is 3–5× priced) |
| **Verification** | judges "is this correct?" | run the oracle (typecheck/lint/test/schema/`git apply --check`) | ◑ partial (quiet-check); broad frontier open |
| **Orchestration** | decides model tier, when to subagent, when to stop, retries | harness routes/caches/stops deterministically | ◻ open & fuzzy — much may be out of hook reach (model-economy bench found arm B unreachable) |
| **Memory** | re-derives/re-computes across turns | deterministic cache / scratchpad / KV | ◑ partial (dedup); caching of command/subagent results open |
| **Meta** | (we) brainstorm candidates each round | mine transcripts to auto-surface "tool could've done this" | ◻ open — **deterministic-first auditor** (closes the loop) |

## The decision rule for new candidates

1. Name the model action that costs tokens/time/turns.
2. Is there a deterministic equivalent that's lossless or strictly recoverable?
3. Which side does it cut — input re-send, output generation, history, or
   round-trips? (Different sides compound; same side overlaps.)
4. Does it stay inside the invariant? If it needs to *force* a model choice, edit
   prior turns, add a dependency, or claim completeness — downgrade to a *skill
   nudge*, *defer*, or *drop*.
5. Ship as a one-shot verb/hook the agent runs — not an auto-injected artifact
   (injection re-bills every turn and goes stale).

## Honest ceiling

Per-operation cuts are huge (90–99%); **session-level** is single-digit-to-low-
double-digit (measured ~14% pooled, higher on log/CI-heavy or weak-model+large-repo
work). Levers compound only across *different* layers. Always measure on the real
workload; never headline a per-op number as a session number.

## Open frontier (ranked by leverage)

1. **`quiet-patch` (output side)** — biggest untapped: output tokens are the
   expensive, serial half. Deferred from round 2; the next concrete build.
2. **Deterministic-first auditor (meta)** — turns the lens on transcripts to find
   the next candidates automatically (the repo already has
   `bench/session-savings.py` scanning transcripts — extend that machinery).
3. **Orchestration (harness)** — highest ceiling, lowest feasibility from a
   plugin/hook; research feasibility before committing.
4. **Verification & memory** — broaden quiet-check into a verdict family; cache
   command/subagent results (staleness-gated, like dedup).
