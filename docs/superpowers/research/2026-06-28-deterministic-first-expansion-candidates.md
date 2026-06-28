# Deterministic-first expansion — candidate AI actions to shift off the model

**Date:** 2026-06-28
**Question:** Beyond find/count/extract/verify (already shipped), what *other* AI
actions could move from the model to deterministic tooling to cut cost?
**Method:** three parallel research sweeps — repo-grounded unshipped candidates,
a wide cross-category brainstorm, and external prior art. Raw outputs in
`.superpowers/research/{repo-candidates,wide-brainstorm,prior-art}.md`.

Filtered through quiet-bash's invariant: **mechanical, lossless-or-byte-exact,
no extra LLM call, no regression, zero-dependency.**

---

## Already shipped (excluded)

Verbose command output → summary; large JSON/YAML read → collapse; large
tool/MCP/WebFetch result → spill+collapse; `quiet-query` over spills; the
`deterministic-first` skill + `quiet-verify`/`quiet-agg` (find/count/extract/
parse/verify/repeat/wait via pipelines).

---

## Ranked candidates

Scored on **value** (token/cost impact × frequency), **risk** (regression +
cache safety), and **fit** (invariant + existing architecture + net-new).

| # | Candidate | Action today (model pays) | Deterministic replacement | Value | Risk | Fit |
|---|---|---|---|---|---|---|
| 1 | **Duplicate-read dedup (tail-edit, mtime-gated)** | model re-Reads a file it already read this session; full bytes re-sent | PostToolUse replaces the *just-emitted* re-read with `[unchanged since you read it above @turn N]` when path+range mtime is unchanged | **High** | **Low** | **Full** — uses existing PostToolUse Read hook; tail-edit is cache-safe; lossless (content already above) |
| 2 | **`quiet-check` — build/test/lint verdict + tally** | model reads a log tail to judge pass/fail, count errors/warnings, list first failures | one verb: exit-code verdict + deterministic `N errors / M warnings` + first-K extracted + spill pointer | Med-High | Low | Full, but **partial overlap** with the existing command-wrap (which already surfaces exit code) |
| 3 | **`quiet-wait` — collapse polling** | model polls a condition by re-reading status across many turns | one verb: `until COND` with timeout, returns only the terminal state | Med-High | Low | Full — net-new; skill already lists "wait" but has no verb |
| 4 | **Compact search-output ladder (grep/rg result collapse)** | a huge `grep -r`/`rg` result floods context | PostToolUse collapse of large search results (search runs correctly; spill byte-exact) | High | Low-Med | Full — but it's a *reactive-layer* extension, not a model-action shift |
| 5 | **Prompt-cache stable-prefix audit** (`--sort-keys`, stable spill names) | nondeterministic key order / spill names cause spurious cache misses (10× re-bill) | sort JSON keys, derive stable spill filenames | Med (systemic multiplier) | Low | Full — trivial, multiplies every other saving |
| 6 | **Repo-map / symbol outline (multi-file)** | model reads many files to navigate / find defs | grep/ctags-style compact symbol index injected on demand | High | Med | Mostly — bigger effort; nav-correctness risk; `quiet-outline.sh` already does single files |
| 7 | **Memoized command cache** (`quiet-cache KEY -- CMD`) | model re-runs + re-emits an expensive command whose inputs didn't change | cache summary+spill keyed on cmd+cwd+input mtimes; TTL | High | Med | Mostly — staleness risk |
| 8 | **Math/aggregation/date arithmetic** | model sums/percentiles/date-diffs in its head (tokens + hallucination) | route to `awk`/`date`; add skill rows | Med | Low | Full — but hard to *enforce*; low per-instance tokens |
| 9 | **MCP tool-schema slimming / deferred loading** | per-turn tool-def bloat | native `defer_loading` (doc only) or proxy slimming | Med | Low | Full (native = docs only) |
| 10 | **Cross-turn retroactive masking** (the risky half of dedup) | old large results re-sent every turn | retroactively stub old results | **Highest** (50–57% in studies) | **High** (busts prompt cache unless gated) | Partial — needs `clear_at_least` gating; deferred |

External prior art corroborates the top of this list: observation
masking / output truncation (JetBrains 52.7% cost cut, zero extra LLM call),
pre-agentic prefetch (Copilot 62%), and grep→rg result reduction (83% on one
MCP server). Sources in `prior-art.md`.

---

## Recommendation — implement #1: duplicate-read dedup

**Why #1 over the others, by value-to-risk:**

- **Highest-value lever that is also low-risk.** The dominant cost in agent
  sessions is the *re-send multiplier* (a stateless agent re-sends the whole
  transcript every turn). Re-reading an unchanged file pays that multiplier for
  bytes already in context. The literature's biggest wins (masking/dedup, 50%+)
  all target this category. #10 is the same category but **high-risk** because it
  edits *old* results and busts the prompt cache; #1 is the **cache-safe slice**:
  it edits only the *just-emitted* re-read (a tail edit — the repo's own cache
  analysis confirms tail edits are safe), so it captures much of the value
  without the cache hazard.
- **Lossless + low regression by construction.** The content is still verbatim
  earlier in context, and the stub only fires when the file's mtime is unchanged
  *and* the same byte-range is requested; any change → pass the real content
  through. The model loses nothing it doesn't already have above.
- **Fits the existing architecture cleanly.** `hooks.json` already runs a
  PostToolUse hook on `Read`; this extends that path — no new matcher, no new
  agent surface, mirrors the existing `quiet_result_summarize` shape.
- **Net-new.** Nothing in quiet-bash dedups re-reads today.

**Runner-up:** `quiet-check` (#2) is the safest, smallest pick and the most
"pure" deterministic-first action shift, but it partially overlaps the existing
command-wrap, so its net-new value is mostly the error/warning *tally* — which
`quiet-agg`/`quiet-query` can already approximate over the spill.

**Deliberately not picked now:** #6 (repo-map) and #7 (cache) are high-value but
larger and carry medium risk; #10 (retroactive masking) is the highest-value but
needs cache-gating and is better as a later, carefully-gated project.

---

## Proposed design for #1 (to confirm before building)

A new PostToolUse path (`quiet-dedup`) tracking reads within a session:

- **Track:** on each `Read` result, record `path → (mtime, size, range, turn,
  content-hash)` in a small session-scoped state file (under `QUIET_LOG_DIR`).
- **On a repeat Read** of the same `path`+`range`: if `mtime`+`size` are
  unchanged since the recorded entry, replace the emitted body with a one-line
  stub: `[quiet-bash] unchanged since you read it earlier this session — see the
  prior Read of <path> above. (re-read forced? touch the file or read a different
  range.)`. Otherwise pass the real content through.
- **Guards (no-regression floor):** never stub if the prior read was itself
  collapsed/partial (so the stub can't point at a stub); never stub a different
  byte-range; mtime/size mismatch → always pass through; state is session-scoped
  and pruned like the existing redirect logs.
- **Cache safety:** only the just-emitted result is rewritten (tail edit) — no
  retroactive edits to earlier turns.
- **Surface:** a README row + a `deterministic-first` skill note ("don't re-Read
  unchanged files; the prior read is still above").
- **Tests:** dedup fires on identical re-read; passes through on changed mtime,
  changed range, and when the prior read was collapsed; state pruning works.

If approved, this goes through the normal spec → plan → subagent-driven build.
