# Design: 10 cost-reduction candidates — build + A/B bench all

**Date:** 2026-07-07  
**Status:** approved, pending implementation plan

---

## Context

quiet-bash already ships: command-output collapsing, JSON/file folding, MCP result collapsing, quiet-repomap (auto-surfaced at session start), quiet-env, quiet-conf, quiet-hist, quiet-blame, quiet-wait, quiet-check, grepsearch mode.

Already A/B-tested and rejected: MCP schema deferral (−74% cost regression), JSON auto-stats (no proven benefit at n=40).

This spec covers 10 new first-principles candidates — one prototype + A/B bench per candidate. The goal is a verdict for each: **SHIP / DO NOT SHIP / INCONCLUSIVE**.

---

## Candidate template (applies to all 10)

Each candidate follows:
- **Lever** — which component of `cost = fresh_input + output×3 + cache_creation×1.25 + cache_read×0.1 + turns×transcript_growth` it attacks
- **Hypothesis** — what the prototype does and why it should save cost
- **A/B arms** — baseline (no feature) vs arm-A (feature on)
- **Task shape** — the benchmark task and fixture
- **Primary metric** — cost $ (as in all prior benches)
- **Secondary metrics** — turns, output tokens, pass-rate
- **n** — minimum 20/arm (project floor); use 40/arm + significance test for candidates where n=20 looks noisy
- **Statistical test** — Mann-Whitney U for continuous (cost, turns); Fisher's exact for correctness
- **Bench script** — `bench/<name>.sh`

---

## Candidate 1: Session-brief expansion

**Lever:** Turns  
**Hypothesis:** Beyond repomap (which surfaces import-graph centrality), inject a compact "project brief" at session start: last 5 commit summaries, current branch, recently modified files, and failing test count if cached. This pre-answers the most common first-turn orientation questions, eliminating 1–3 exploration turns — the same mechanism that gave repomap −77% on orientation tasks.

**Arms:**
- A (baseline): session starts cold, no injected brief
- B (brief): session-start hook prepends a ≤200-token project brief (git log --oneline -5, git branch --show-current, git diff --stat HEAD, cached test failure count if `~/.quiet-bash/test-cache` exists)

**Task:** "Summarize the last 3 changes to this repo and name the current branch." Run on the quiet-bash repo itself.  
**Primary metric:** cost $  
**Secondary:** turns, output tok  
**n:** 20/arm  
**Bench script:** `bench/session-brief.sh`

---

## Candidate 2: Output-token directive measurement

**Lever:** Output tokens  
**Hypothesis:** `output-styles/concise.md` is opt-in but unmeasured. Output tokens cost ~3× input; a 20% output cut ≈ 6% session saving. A/B measures the real output-token delta and whether task quality holds.

**Arms:**
- A (baseline): no output style directive
- B (concise): system prompt includes `output-styles/concise.md` verbatim

**Task:** A mid-complexity coding task (e.g., "add a --verbose flag to quiet-map.sh and update its usage string"). Graded pass/fail by checking the flag exists in the output file.  
**Primary metric:** cost $  
**Secondary:** output tok, turns, pass-rate  
**n:** 20/arm  
**Bench script:** `bench/output-directive.sh`

---

## Candidate 3: Same-session tool-call dedup

**Lever:** Fresh input tokens  
**Hypothesis:** Agents often read the same file or run the same command twice in one session (e.g., `cat package.json` at session start and again mid-task). The second call's result is already in context; quiet-bash could serve it from an in-session key→result map (keyed by `tool_name + args hash`), emitting a back-reference instead of re-running and re-emitting the full output. Zero fresh tokens on the duplicate.

**Arms:**
- A (baseline): all tool calls execute normally
- B (dedup): `QUIET_DEDUP=1` — quiet-bash maintains a per-session hash of `sha256(cmd) → spill_path`; on a cache hit, emits `[duplicate: same as call N, spilled at <path>]` instead of re-running

**Task:** A task that provably re-reads one file twice: "read package.json and tell me the version; then modify install.sh to print that version at startup." The agent will read package.json at the start and again when writing install.sh. Graded by checking the version appears correctly in install.sh.  
**Primary metric:** cost $  
**Secondary:** input tok (fresh vs cached), pass-rate  
**n:** 20/arm  
**Bench script:** `bench/dedup.sh`

---

## Candidate 4: find/ls directory collapsing

**Lever:** Fresh input tokens  
**Hypothesis:** `find . -name "*.ts"` on a large repo returns hundreds of lines. grepsearch mode already collapses grep output per-file. The same pattern applies to find/ls: group by parent directory, emit `dir/: N files matching` instead of every path. A 500-line find output → ~20 directory-count lines.

**Arms:**
- A (baseline): find/ls output passes through unchanged
- B (collapsed): PostToolUse hook detects find/ls with >50 lines, collapses to per-directory counts (preserves full output on disk)

**Task:** "List all shell scripts in this repo." Run on a fixture with ~200 .sh files spread across 5 directories.  
**Primary metric:** cost $  
**Secondary:** input tok, turns, pass-rate (did the agent find the right answer?)  
**n:** 20/arm  
**Bench script:** `bench/find-collapse.sh`

---

## Candidate 5: git diff hunk-only mode

**Lever:** Fresh input tokens  
**Hypothesis:** `git diff` and `git log -p` include 3 lines of unchanged context around each hunk (configurable but default). For a 500-line diff, these context lines can double the token count. A quiet-bash post-processor strips them, keeping only `@@` hunk headers and `+`/`-` lines. The full diff is still on disk.

**Arms:**
- A (baseline): git diff/log -p output passes through unchanged
- B (hunk-only): PostToolUse hook detects `git diff` / `git log -p` output, strips context lines, prepends `[hunk-only: full diff at <path>]`

**Task:** "What files changed in the last commit, and what was the net line change?" Run on a fixture commit with ~30 changed files.  
**Primary metric:** cost $  
**Secondary:** input tok, pass-rate  
**n:** 20/arm  
**Bench script:** `bench/diff-hunk.sh`

---

## Candidate 6: Cache prefix health check

**Lever:** Cache efficiency  
**Hypothesis:** quiet-bash's PostToolUse rewrites (log redirect, value-folding) change the tool result content. If these changes perturb content that was already part of a cache prefix, they bust the prefix and force expensive cache_creation instead of cheap cache_read (0.1×). This is a measurement candidate — no new feature, but a controlled experiment: run the same 3-arm agentic bench (baseline / cmd-only / full) and record `cache_read %` per arm. If cmd-only or full arm shows lower cache_read % than baseline, the hooks are busting the prefix.

**Arms:**
- A (baseline): no hooks
- B (cmd-only): Bash hook only
- C (full): Bash + Read/MCP hooks

**Task:** Same as the existing `bench/agentic.sh` (short read-only tasks on astra-migrations-core), but capture `cache_read_tokens / total_input_tokens` per arm.  
**Primary metric:** cache_read %  
**Secondary:** cost $  
**n:** 20/arm  
**Bench script:** `bench/cache-health.sh` (adapt agentic.sh to capture cache split)

---

## Candidate 7: One-shot session context injection

**Lever:** Fresh input tokens (per turn)  
**Hypothesis:** The `adapters/claude-code-sessionstart.sh` hook injects repomap + env output into the system prompt. In Claude Code, a system-prompt addition re-appears in every turn's `cache_creation` window once the cache prefix grows past it. If the injected content is large (e.g., a 2,000-token repomap), it adds 2,000 tokens of cache_creation overhead on every turn after the prefix exceeds it. Restructuring the injection as a first-turn `user` message (which scrolls off as the session ages) instead of a system prompt addition would eliminate that per-turn overhead after turn N.

**Arms:**
- A (baseline): injected context in system prompt (current behavior)
- B (first-turn): injected context as a pre-task `user` message in turn 1 only

**Task:** A 10-turn session driven by a scripted sequence of 10 bash commands (grep, find, cat operations) against this repo — long enough for the per-turn overhead to compound. Measure cost across the full session, not just the first turn.  
**Primary metric:** cost $ (cumulative, 10-turn session)  
**Secondary:** cache_creation tok  
**n:** 10/arm (each "run" is a 10-turn session; fewer runs needed since the effect is cumulative)  
**Bench script:** `bench/injection-placement.sh`

---

## Candidate 8: Selective model downgrade

**Lever:** Cost per token  
**Hypothesis:** The prior model-economy gate used a blunt all-subagents downgrade (main=Sonnet, subagents=Haiku) and got an INCONCLUSIVE result — Haiku subagents took more turns and offset the per-token savings. The hypothesis is that *selective* downgrade works: downgrade only clearly mechanical subagents (search/grep/file-read tasks) while keeping Sonnet for reasoning/synthesis subagents. Requires tagging subagents by type in the task, or using a heuristic (subagents with short prompts = mechanical = Haiku).

**Arms:**
- A (baseline): all subagents inherit main model
- B (selective): subagents whose task prompt matches `/grep|find|read|list|search/i` run on Haiku; others inherit

**Task:** A task that provably spawns both a search subagent and a reasoning subagent (e.g., "find all TODO comments in the codebase and summarize the themes"). Graded by checking the summary mentions at least 2 real TODO themes.  
**Primary metric:** cost $  
**Secondary:** pass-rate, turns  
**n:** 20/arm  
**Bench script:** `bench/model-economy-selective.sh`

---

## Candidate 9: WebFetch/Search result measurement

**Lever:** Measurement / threshold tuning  
**Hypothesis:** `proxy/quiet-mcp-proxy.mjs` collapses large MCP/WebFetch results. The collapse threshold is configured but has never been A/B-tested on real WebFetch-heavy tasks to validate it saves cost without causing re-fetches. This bench measures the real session saving and optimal threshold (current default vs half / double).

**Arms:**
- A (baseline): no MCP result collapsing
- B (current threshold): collapse at current default
- C (half threshold): collapse at 50% of default (more aggressive)

**Task:** A research task that calls WebFetch 3+ times (e.g., "summarize the README of 3 GitHub repos"). Graded by checking all 3 are mentioned in the output.  
**Primary metric:** cost $  
**Secondary:** pass-rate, turns  
**n:** 20/arm  
**Bench script:** `bench/webfetch-collapse.sh`

---

## Candidate 10: Anti-preamble directive

**Lever:** Output tokens  
**Hypothesis:** Models often prepend "Sure, I'll help you with that..." or post-pend "Let me know if you need anything else." These add output tokens that cost 3× input. A minimal directive ("no preamble, no postamble, no acknowledgment — just output the result") tests whether this cuts output tokens without affecting task quality.

**Arms:**
- A (baseline): no directive
- B (anti-preamble): system prompt adds a 1-sentence anti-preamble rule

**Task:** A simple code-generation task (e.g., "write a bash function that counts lines in a file"). Graded by checking the function is syntactically valid bash.  
**Primary metric:** output tok  
**Secondary:** cost $, pass-rate  
**n:** 20/arm  
**Bench script:** `bench/anti-preamble.sh`

---

## Execution order

Run in this order to get the highest-signal results first:

1. **C2** (output-token directive) — pure measurement, no new code in core
2. **C10** (anti-preamble) — same, minimal build
3. **C6** (cache prefix health) — measurement, adapts existing bench
4. **C1** (session-brief) — extends repomap pattern, high expected impact
5. **C4** (find/ls collapse) — extends grepsearch, low-risk build
6. **C5** (git diff hunk-only) — deterministic post-processor
7. **C3** (same-session dedup) — stateful hook, more complex
8. **C7** (one-shot injection) — adapter change
9. **C8** (selective model downgrade) — needs subagent tagging
10. **C9** (WebFetch threshold) — needs live WebFetch tasks, most env-dependent

---

## Shared conventions

- All benches use `claude-haiku-4-5` as the test model (consistent with prior benches)
- Cost measured in $ from `--output-format stream-json` (not raw token counts)
- All bench scripts print a summary table + a SHIP / DO NOT SHIP / INCONCLUSIVE verdict
- Verdicts committed to `bench/RESULTS.md` after each run (append-only)
- Negative results are as valuable as positive — document and keep

---

## What success looks like

A candidate SHIPS if:
- Cost reduction is statistically significant (Mann-Whitney U p < 0.05 at n=20) **and**
- Pass-rate equals baseline (zero quality regression)

A candidate is INCONCLUSIVE if:
- Direction is positive but p ≥ 0.05 (underpowered) — re-run at n=40 before deciding

A candidate is DO NOT SHIP if:
- Cost is directionally higher than baseline on >50% of individual runs
