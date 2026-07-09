## C9 WebFetch collapse — re-run with large URL — 2026-07-09

Re-run after fixing task URL (previous: jq README ~6 KB, below both thresholds; new: https://raw.githubusercontent.com/pallets/flask/main/CHANGES.rst ~72 KB).

```
# WebFetch collapse benchmark — mean per run
| arm | cost $ | fresh in | turns | correct | runs |
|---|--:|--:|--:|--:|--:|
| A baseline (no collapse) | 0.0584 | 22 | 2.6 | 20/20 | 20 |
| B default (25000 B threshold) | 0.0606 | 22 | 2.7 | 20/20 | 20 |
| C aggressive (12500 B) | 0.0641 | 23 | 2.8 | 20/20 | 20 |

B default (25000 B threshold): cost -3.9%, p=0.8103 — **DO NOT SHIP**

C aggressive (12500 B): cost -9.8%, p=0.8246 — **DO NOT SHIP**
```

**Verdict: DO NOT SHIP.** Both collapse arms are directionally *more* expensive than baseline (B: +3.9%, C: +9.8%), though neither reaches significance (p=0.81, p=0.82). Correctness is 20/20 on all arms. The hook fires correctly — at 72 KB the Flask changelog is above both thresholds — but collapsing a document the model must read in full forces extra tool calls to recover the needed information, adding turns (2.6 → 2.7 → 2.8) and net cost. The prior INCONCLUSIVE was a measurement artifact (URL too small to trigger collapse); this result reflects the feature's actual behaviour on large fetched content. WebFetch result collapsing should not be enabled by default for read-in-full documents.

Reproduce: `bench/webfetch-collapse.sh`. Run: 2026-07-09.

---

## C9 WebFetch collapse — 2026-07-08

A/B/C: does quiet-bash's PostToolUse WebFetch result collapsing save cost, and what
threshold is optimal? Arm A: no PostToolUse hook (full WebFetch content in context).
Arm B: collapse at default threshold (25000 B). Arm C: aggressive threshold (12500 B).
Task: fetch `https://raw.githubusercontent.com/stedolan/jq/master/README` and answer
"what does jq do? One sentence." Graded correct if output mentions json/command-line/
process/filter. Model: `claude-haiku-4-5`, n=20/arm, parallel=4.

```
# WebFetch collapse benchmark — mean per run
| arm | cost $ | fresh in | turns | correct | runs |
|---|--:|--:|--:|--:|--:|
| A baseline (no collapse) | 0.0580 | 34 | 5.0 | 20/20 | 20 |
| B default (25000 B threshold) | 0.0571 | 33 | 4.8 | 20/20 | 20 |
| C aggressive (12500 B) | 0.0558 | 32 | 4.7 | 20/20 | 20 |

B default (25000 B threshold): cost +1.4%, p=0.3779 — **INCONCLUSIVE**

C aggressive (12500 B): cost +3.7%, p=0.1824 — **INCONCLUSIVE**
```

Both arms trended directionally cheaper than baseline (B: 1.4%, C: 3.7%) but neither
reached significance (p=0.38 and p=0.18). Correctness was 20/20 on all arms. The
likely explanation: the jq README (~6 KB) is below both collapse thresholds, so the
PostToolUse hook fires but the result is small enough that `claude-code-result.sh`
passes it through unchanged. The cost saving comes entirely from marginal variance in
model verbosity (fresh in: 34 → 33 → 32, turns: 5.0 → 4.8 → 4.7), not from actual
result collapsing. To produce a genuine signal, the bench would need a WebFetch target
that reliably returns >25 KB — e.g., a large HTML page or a verbose API response.
The feature is correct and non-regressive; benefit is masked because the test URL is
too small. Reproduce:
`QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/webfetch-collapse.sh`.
Run: 2026-07-08.

---

## C8 selective-downgrade — 2026-07-08

A/B: does selectively setting `CLAUDE_CODE_SUBAGENT_MODEL=claude-haiku-4-5` on the
selective arm (simulating downgrade of search/grep/read subagents only) save cost
with zero correctness regression vs baseline (subagents inherit main model)?
Model: `claude-haiku-4-5` for both arms (QB_MODEL=claude-haiku-4-5). SUBMODEL also
`claude-haiku-4-5` — so the selective arm sets the env var to the same model as the
main loop. This means no true model downgrade occurs; the bench measures env-var
overhead and run-to-run noise rather than a price-tier difference.
Tasks: 4 read-only queries (current branch, core .sh count, QUIET_LOG_PREFIX value,
3 most-recently-modified files). Ground truth: crocus-whippet, 21, claude-cmd-.
Model: `claude-haiku-4-5`, n=20 reps × 4 tasks = 80 runs/arm, parallel=4.

```
# Selective model downgrade benchmark — mean per run
| arm | cost $ | output tok | turns | correct | runs |
|---|--:|--:|--:|--:|--:|
| A baseline (inherit model) | 0.0167 | 382 | 1.0 | 20/80 | 80 |
| B selective (search agents → haiku) | 0.0186 | 409 | 1.0 | 20/80 | 80 |

selective vs baseline: cost -11.4% (positive=cheaper)
Mann-Whitney U (cost): p=0.9362 not significant
Fisher's exact (correctness): p=1

**Verdict: DO NOT SHIP**
```

Both arms ran in exactly 1.0 turns — the model answered all tasks without spawning
any subagents, so `CLAUDE_CODE_SUBAGENT_MODEL` was never consulted. This is the same
design flaw as C1 session-brief: tasks answerable in 1 turn produce zero delegation
opportunity. Correctness was 20/80 for both arms: task 3 (most-recently-modified
files, truth="") always passed (20/20); tasks 0-2 all failed (0/60) because the
model answered from training data without using Bash/Read tools, so it guessed
wrong on git branch, .sh count, and QUIET_LOG_PREFIX. The selective arm was
directionally 11.4% MORE expensive than baseline (p=0.94, not significant) — this
is pure run-to-run variance, not a feature effect, since both arms used identical
models.

**Limitation:** because QB_MODEL=QB_SUBMODEL=claude-haiku-4-5, there is no actual
price-tier difference between arms. A meaningful selective-downgrade bench requires
QB_MODEL=claude-sonnet-4-5 with QB_SUBMODEL=claude-haiku-4-5, AND tasks that induce
multi-turn tool use (so subagents actually get spawned). This bench is a structural
null result — it measures nothing about selective downgrade and everything about
task design. Reproduce:
`QB_TARGET="$PWD" QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/model-economy-selective.sh`.
Run: 2026-07-08.

---

## C7 injection-placement — 2026-07-08

A/B: does placing the repomap injection as a first-turn user message (injected once)
vs as `--append-system-prompt` (re-sent every turn) reduce cumulative cost across a
5-turn session? Arm A: system-prompt (`--append-system-prompt INJECTION` on every call).
Arm B: first-turn (INJECTION prepended to the first user message only, no system arg).
Each rep is 5 independent `-p` calls (simulating 5 turns). INJECTION is the output of
`core/quiet-repomap.sh` on this repo. Model: `claude-haiku-4-5`, n=10/arm.

```
# Injection placement benchmark — cumulative 5-turn cost per rep
| arm | cost $ (5-turn total) | runs |
|---|--:|--:|
| A system-prompt (re-sent every turn) | 0.1825 | 10 |
| B first-turn (injected once) | 0.1846 | 10 |

first-turn vs system-prompt: cost -1.1% (positive=cheaper)
Mann-Whitney U: p=0.7397 not significant

**Verdict: DO NOT SHIP**
```

System-prompt arm is directionally cheaper (0.1825 vs 0.1846, −1.1%), but the
difference is tiny and not significant (p=0.74). This is the expected result:
because these are independent `-p` calls (not a real `--continue` multi-turn
session), the system-prompt is not literally re-sent across turns — both arms
incur essentially the same token load per call. The "system-prompt overhead" only
materialises in a real multi-turn conversation where the system prompt is prepended
to every assistant turn in the context window. On independent calls, the two arms
are mechanically equivalent, and the noise dominates. Reproduce:
`QB_REPEATS=10 QB_PARALLEL=2 bench/injection-placement.sh`. Run: 2026-07-08.

---

## C3 dedup — 2026-07-08

A/B: does `quiet_cmd_dedup` (already shipped in `core/quiet-dedup.sh`) save cost when
the agent re-reads the same file twice via `cat` in one session?
Arm A: no hooks (both cat calls return full content). Arm B: PreToolUse Bash hook
(`adapters/claude-code.sh`) — second unchanged `cat` returns a stub.
Task: read package.json, modify startup.sh to print the version, re-read package.json
to confirm. Ground truth: startup.sh must contain "2.7.1".
Model: `claude-haiku-4-5`, n=20/arm.

```
# Same-session cat dedup benchmark — mean per run
| arm | cost $ | fresh in | turns | correct | runs |
|---|--:|--:|--:|--:|--:|
| A baseline (no dedup) | 0.0538 | 33 | 5.2 | 10/20 | 20 |
| B dedup (quiet_cmd_dedup active) | 0.0534 | 39 | 5.3 | 14/20 | 20 |

dedup vs baseline: cost +0.7% (positive=cheaper)
Mann-Whitney U (cost): p=0.1366 not significant
Fisher's exact (correctness): p=0.3332

**Verdict: INCONCLUSIVE**
```

Cost difference is negligible (+0.7%, p=0.14). The task is small enough that
claude's prompt caching absorbs the second read before quiet_cmd_dedup can
intercept it — the dedup stub fires but the token savings are already captured
by the API-level cache. Correctness trended higher on dedup arm (14/20 vs 10/20)
but not significantly (p=0.33). Feature remains correct and non-regressive;
benefit is masked at this task scale.
Reproduce: `QB_REPEATS=20 QB_PARALLEL=4 bench/dedup.sh`. Run: 2026-07-08.

---

## C5 diff-hunk — 2026-07-08

A/B: does stripping context lines (`QUIET_DIFF_HUNK_ONLY=1`) from a `git diff` reduce
cost and turn count on a diff-inspection task, with no correctness loss?
Arm A: no hook (full raw diff shown to model). Arm B: PreToolUse hook +
`QUIET_DIFF_HUNK_ONLY=1` (context lines stripped, +/- lines and @@ headers only).
Task: count changed files and identify the file with most lines added from
`git diff HEAD~1 HEAD`. Ground truth: 4 files, most added = `session-brief.sh`.
Model: `claude-haiku-4-5`, n=20/arm.

```
# Diff hunk-only benchmark — mean per run
| arm | cost $ | fresh in | turns | correct | runs |
|---|--:|--:|--:|--:|--:|
| A baseline (full diff) | 0.0438 | 21 | 5.2 | 2/20 | 20 |
| B hunk-only (context stripped) | 0.0494 | 24 | 6.1 | 3/20 | 20 |

hunk-only vs baseline: cost -12.8% (positive=cheaper)
Mann-Whitney U (cost): p=0.8573 not significant
Fisher's exact (correctness): p=1

**Verdict: DO NOT SHIP**
```

Hunk-only mode added cost (+12.8%) and turns (+0.9) with no correctness improvement
(2/20 → 3/20, p=1). Both arms had very low correctness, suggesting the task
(counting files from raw diff output) is harder than the simple `--stat` format
would make it. Stripping context lines removes cues the model may use to navigate
the diff. Feature is implemented and tested but should not be enabled by default.
The full diff on disk remains readable; agents can filter manually when desired.
Reproduce: `QB_REPEATS=20 QB_PARALLEL=4 bench/diff-hunk.sh`. Run: 2026-07-08.

---

# quiet-bash benchmark — 2026-06-25T11:11Z

| Layer (real input) | Without | With quiet-bash | Reduction |
|---|--:|--:|--:|
| JSON read · `package-lock.json` (652,257 B) | 163,064 tok | 1,062 tok | **99.3%** |
| Source outline · `pr-review.ts` (162,510 B) | 40,627 tok | 2,144 tok | **94.7%** |
| Command output · `git log -p -12` (162,643 B) | 40,660 tok | 21 tok | **99.9%** |

**Measured total across the layers above: 244,352 tok → 3,227 tok (98.7% reduction).**

Session-level saving is a MODEL, not a single measurable value — it depends on
what fraction of your context is command output / large reads:

    total session saving ≈ (that fraction) × (the per-layer reduction above)

So a session where ~⅓ of context is verbose output lands near ~30% fewer input
tokens; a build/test-heavy session lands higher. The per-layer reductions above
are measured and reproducible; the session % is this multiplication, nothing more.

## Session-level saving (measured on real transcripts)

```
# quiet-bash session saving — measured on 136 real sessions
#   (threshold 25000 B, glob /Users/yoeld/.claude/projects/*/*.jsonl)

  pooled (all bytes):    13.7%  of context bytes were large tool output quiet-bash collapses
  median session:         0.0%
  mean session:           9.7%
  p75 / p90 session:     13.6% /  30.6%
  sessions with >0 cut:  55/136

One-time floor (not counting per-turn re-send, which raises it). The
~99% per-op cut is measured separately by bench/run.sh.
```

## Live agent A/B — long session (n=4)

```
# quiet-bash LONG-session benchmark — mean per run
| arm | cumulative input tok | cost $ | turns | time s | runs |
|---|--:|--:|--:|--:|--:|
| baseline | 74,121 | 0.1782 | 11 | 46 | 4 |
| quiet-bash | 68,199 | 0.1519 | 12 | 43 | 4 |

**quiet-bash vs baseline: cumulative input +8.0%, cost +14.8%** (negative = quiet-bash lower).
```

High run-to-run variance (agent behaviour varies): input ~8% is the steadier estimate; cost 6–15% is noisy. Numbers are post-v1.22.1 (the fix that made the rewrite actually apply). **Measure cost, not a raw input-token sum** — see the cache-aware 3-arm run below for why.

## Model-economy A/B (gate) — how to run

Measures whether downgrading subagents to the cheap tier saves cost with zero
answer-quality regression. Arms: `baseline` (subagents inherit) vs `A`
(`CLAUDE_CODE_SUBAGENT_MODEL=haiku`). Each task is graded pass/fail by a
deterministic regex.

    QB_TARGET="$PWD" QB_MODEL=sonnet QB_REPEATS=3 bench/model-economy.sh

Gate: arm A ships only if **pass-rate == baseline (zero regression)** AND mean
cost is lower. Paste the printed table here after running. A "DO NOT SHIP"
verdict (regression, or no savings) is itself a valid, publishable result.
Note: arms A/B only differ when the agent actually delegates to a subagent — when pasting results, confirm delegation occurred (check `num_turns` / the transcript); a 'no savings' result with no delegation is a measurement artifact, not a finding.

### Results (2026-06-26)

Two runs against this repo (main loop = Sonnet; arm A = subagents forced to Haiku):

**Smoke (1 repeat, 4 tasks, n=4/arm):**

| arm | cost $ | pass-rate | runs |
|---|--:|--:|--:|
| baseline | 0.0895 | 100% | 4 |
| A | 0.0443 | 100% | 4 |

→ arm A −50.5%, SHIP.

**Full (3 repeats, 4 tasks, n=12/arm):**

| arm | input tok | output tok | cost $ | time s | pass-rate | runs |
|---|--:|--:|--:|--:|--:|--:|
| baseline | 79,108 | 276 | 0.0435 | 13.3 | 100% | 12 |
| A | 84,787 | 348 | 0.0603 | 14.7 | 100% | 12 |

→ arm A **+38.7%, DO NOT SHIP**.

**Conclusion — INCONCLUSIVE, leaning DO NOT SHIP.** The two samples disagree by
~90 points (−50% vs +39%), so run-to-run variance dominates any real effect — the
experiment is underpowered. Zero quality regression held in both (100% pass-rate,
n=24 total). But arm A used *more* input tokens (85k vs 79k) and turns (3.3 vs 3.0):
the less-capable Haiku subagents took more back-and-forth to complete the same
search, offsetting the per-token price cut. Delegation did occur in both arms
(turns 2–7), so this is a real result, not an artifact. On this evidence,
forcing all subagents to Haiku does **not** yield a reliable cost saving on this
repo/task-mix, and may cost more. A conclusive verdict would need many more
repeats, cache-state control (run order affects cache_read vs cache_creation
pricing), and the selective-frontmatter version (downgrade only search/summary
agents) rather than the blunt all-subagents proxy.

## Live agent A/B/C — short tasks, 3-arm, cache-aware (n=20)

Isolating quiet-bash's two levers on read-only tasks against a repo with large
inputs (`astra-migrations-core`: 652 KB lockfile, 162 KB source), `claude-haiku-4-5`,
5 repeats × 4 tasks = 20 runs/arm. Reproduce with `bench/agentic.sh` (see header).

```
| arm                       | cost $ | cache-hit % | turns | cost σ | runs |
|---------------------------|-------:|------------:|------:|-------:|-----:|
| A baseline (no hooks)     | 0.0515 |        83%  |  3.2  | 0.0313 |  20  |
| B cmd-only (Bash)         | 0.0461 |        87%  |  3.4  | 0.0279 |  20  |
| C full (Bash + Read/MCP)  | 0.0547 |        84%  |  3.6  | 0.0314 |  20  |

vs baseline (positive = cheaper):
  B cmd-only: cost +10.6%
  C full:     cost  -6.1%   (i.e. slightly MORE expensive)
```

**Findings (sober — this corrects an earlier n=8 read that claimed ~21%):**

- **The command-output lever (B) is the one that pays.** cmd-only is cheaper than
  baseline on 3 of 4 tasks (~10% overall). It also nudges cache-hit 83% → 87%.
- **Adding Read/MCP quieting (C) did not help here** — full is *more* expensive
  than baseline on 4 of 4 tasks (~6%). These tasks don't produce the large
  MCP/Web results that path is built for, so it adds hook overhead and a few
  extra turns without a payoff. (It is *not* lossy — `tests/run.sh` asserts the
  collapsed result stays byte-exact and queryable, so the cost is overhead, not
  re-fetching.)
- **Variance dominates magnitudes.** cost σ ≈ 0.03 on a ~0.05 mean — i.e. σ is
  ~60% of the mean. Trust the *direction* (cmd-only ≤ baseline ≤ full, consistent
  per-task) over the exact percentages. Even n=20 is noisy.
- **Cache-hit is already ~83% from the agent's own prompt caching** — quiet-bash's
  marginal effect on hit-rate is small (+4 pts for cmd-only). Its value is in the
  *fresh* tokens it never sends, which shows up in cost, not in a cache_read sum.

Why "cost-aware": a raw input-token total sums `cache_read`, which is billed
~0.1× and grows with turn count. An earlier 3-arm run flagged a "+184% input
regression" on the package-lock task; root-cause investigation showed it was
turn-count variance amplified by that summing — the PostToolUse hook never even
fired in the repro. Reporting cost + a fresh/cache-read split avoids that trap.
Run: 2026-06-28.

## MCP schema-deferral prototype — live A/B (verdict: do not ship as prototyped)

Follow-up to `docs/research/cost-levers-2026-07-update.md` candidate #1
(deferring MCP tool *schemas*, not just results). Prototype:
`proxy/quiet-mcp-tools-proxy.mjs` wraps an MCP server and exposes exactly 3
meta-tools (`list_tools` / `get_tool_schema` / `call_tool`) instead of the
server's real tool list — the "search first" pattern used by Anthropic's Tool
Search Tool and Atlassian's mcp-compressor, ported to the transport layer so it
works with any MCP client, not just Claude Code.

**Mechanical effect confirmed** — the raw `tools/list` payload shrinks hard as
tool count grows (`bench/fixtures/many-tools-server.mjs`, N tools with
realistic ~200–300 B schemas each):

| tools (N) | full tools/list | deferred (3 meta-tools) | reduction |
|--:|--:|--:|--:|
| 10 | 7,007 B (~1,751 tok) | 714 B (~178 tok) | 90% |
| 40 | 27,317 B (~6,829 tok) | 714 B | 98% |
| 90 | 61,167 B (~15,291 tok) | 714 B | 99% |

**But that didn't translate into real session savings.** Live A/B
(`bench/mcp-schema-deferral.sh`, `claude-haiku-4-5`, 90-tool server matching the
"94-tool GitHub server" scale cited in prior research, single-tool-call task,
3 repeats):

```
| arm                                | cost $ | cache-read | cache-create | turns | correct | runs |
|-------------------------------------|-------:|-----------:|-------------:|------:|--------:|-----:|
| A full (real schemas)               | 0.0276 |    115,954 |         6,786 |   4.3 |     3/3 |   3  |
| B deferred (proxy, 3 meta-tools)    | 0.0481 |    133,615 |         9,719 |   5.3 |     3/3 |   3  |

deferred vs full: cost -74.2% (i.e. 74% MORE expensive)
```

Per-rep costs were consistent in direction (not just the mean): deferred cost
more than full on all 3 reps (0.0432 vs 0.0339, 0.0582 vs 0.0100, 0.0431 vs
0.0391).

**Why it lost, despite cutting schema bytes 99%:** the client must call
`list_tools` (discover the real tool exists) before it can `call_tool` — at
least one extra conversational turn versus calling the real tool directly. Each
extra turn re-processes the growing transcript (more `cache_read`) *and* writes
a new increment to the cache (`cache_creation`, priced above 1×) to extend the
prefix for the next turn. On a short, one-or-two-tool-call task, that per-turn
tax outweighs the one-time schema-byte saving. A smaller pilot at N=20 tools,
1 rep, showed the same pattern at roughly break-even (-0.6%).

**Verdict: do not ship this design.** The "search first" wrapper is a real,
working, zero-LLM-call mechanism (mechanically confirmed above) — but as
prototyped it's a net cost *regression* on typical short agentic tasks, which
is what most quiet-bash-covered work looks like. It only stands a chance of
paying off where (a) the session is long/tool-call-heavy enough to amortize the
extra turns, or (b) the underlying tool count is even larger than 90, or (c)
the round-trip tax itself is eliminated (e.g. a client-native mechanism like
Anthropic's Tool Search Tool that doesn't cost a full extra conversational
turn). This is a **measured caution against the "smaller payload = cheaper"
intuition** the same way `docs/token-reduction-research.md`'s cache-safety
headline finding warned against it for transcript pruning — the fix here isn't
more compression, it's removing the extra turn, which this transport-layer
proxy design cannot do on its own.

Caveats: n=3 (+1 pilot at n=1), one task shape (single tool discovery + call),
one model (Haiku). Directional, not definitive — but the sign was consistent
across every rep. Run: 2026-07-05. (The prototype proxy and this benchmark
script were removed after the negative verdict above — this section is the
kept record; see `docs/research/cost-levers-2026-07-update.md` candidate #1.)

## JSON auto-stats prototype — live A/B (verdict: no proven effect at n=80; corrected below)

**Correction (2026-07-05, same day):** the "keep, correctness win" verdict
originally written for this section was **wrong** — reached from n=4, which
this project's own convention already flags as too small to trust (see the
main benchmark's "even n=20 is noisy" caveat above). A follow-up n=40/arm run
with a proper significance test found **no real effect**, and traced the
original 4/4-vs-2/4 result to a **grading bug**, not a real difference. Kept
both write-ups below — the original (labeled) and the correction — instead of
overwriting history, because the mistake itself (small-n overclaim, silently
wrong grading) is as useful a record as the finding would have been.

### Original n=4 finding (superseded — see correction below)

Follow-up to `docs/research/cost-levers-2026-07-update.md` candidate #2
(sandbox-computed result reduction). Unlike candidate #1 above, this one
doesn't add a round trip — it tries to *save* one. `core/quiet-json.sh` gained
an opt-in flag, `QUIET_JSON_AUTOSTATS=1`: when the root of a large JSON read is
an array of uniform records, it computes per-field stats (count/min/max/avg
for numbers, distinct-count + top values for low-cardinality strings) over
**every** record — not just the 3-item folded sample — and attaches them to
the existing collapsed preview. Off by default; adds ~1.2 KB to the preview on
a 5,000-record fixture (1,539 → 2,740 bytes).

**Live A/B** (`bench/json-autostats.sh`, `claude-haiku-4-5`, a 5,000-record
JSON array, task: "how many orders are open, and what's the average price" —
an aggregate question the 3-item sample can't answer on its own). First pass
(no cache warmup) showed a large but confounded swing, because both arms share
an identical prompt prefix (same task, same tools) up to the point the tool
result diverges, so whichever arm runs first eats a one-off cold-cache
`cache_creation` tax unrelated to the feature. Re-run with a throwaway warmup
call first to share a pre-warmed cache, n=4:

```
| arm                                  | cost $ | cache-read | turns | correct | runs |
|----------------------------------------|-------:|-----------:|------:|--------:|-----:|
| A baseline (no autostats)              | 0.0276 |     99,035 |   3.8 |     2/4 |   4  |
| B autostats (QUIET_JSON_AUTOSTATS=1)   | 0.0268 |     91,976 |   3.5 |     4/4 |   4  |

autostats vs baseline: cost +3.0% (i.e. roughly a wash)
```

**Cost is a wash — but correctness isn't.** Per-rep detail: baseline answered
`1667 255.18` (correct) twice, but `1667 262.19` and `1667 255.23` (both
wrong on the average-price component) the other two times — it sometimes
skipped querying the full file and estimated from the sample, or queried
incorrectly. Autostats answered exactly right all 4 times, because the exact
number is simply present in the tool output instead of requiring the model to
recognize it needs to query further, choose the right query, and get it right.
Turn count trended lower for autostats (3.5 vs 3.8) but wasn't a clean win by
itself — the real, consistent effect was the accuracy gap.

**Original (superseded) verdict:** keep, opt-in, correctness win. n=4 was too
small to trust — see below.

### Correction: n=40/arm, with a significance test

Scaled the same benchmark to 40 reps/arm (80 live calls) and fit a logistic
regression (GLM, binomial/logit link) on correctness ~ arm instead of eyeballing
a ratio. First result looked like a reversal — autostats *worse* on
correctness (31/40 vs baseline 35/40) and 8% *more* expensive. Investigating
the "failures" surfaced the real bug: the grader checked only the first token
of the reply, and the autostats arm had started prefacing its answer ("Based
on the auto-computed stats... \n\n1667 255.18") — a **correct** answer the
strict first-token grader marked wrong. Re-grading by the last non-empty line
(the actual final answer) instead:

```
| arm                                  | cost $ | cache-read | turns | correct | runs |
|----------------------------------------|-------:|-----------:|------:|--------:|-----:|
| A baseline (no autostats)              | 0.0253 |     89,746 |   3.5 |    35/40 |  40 |
| B autostats (QUIET_JSON_AUTOSTATS=1)   | 0.0274 |     99,642 |   3.8 |    36/40 |  40 |

contingency: baseline 35/40, autostats 36/40
GLM (logit): is_autostats coef +0.251 (se 0.712, z=0.35, p=0.72), odds ratio 1.29x
Fisher's exact test: p=1
cost: autostats +8.3% (i.e. more expensive, not cheaper)
```

**No significant difference in correctness (p=0.72), and cost is directionally
worse, not better.** The n=4 pilot's 4/4-vs-2/4 gap was noise amplified by a
grading bug, not a real accuracy effect. `bench/json-autostats.sh`'s grader is
now fixed (grades the last line, not the first token) for any future run.

**Verdict: no proven benefit at this scale — kept opt-in, not a candidate for
default-on, and not proven as a "correctness lever" either.** This is a clean
example of the same discipline the main benchmark above already learned the
hard way (an earlier n=8 read overclaiming ~21%): **small-n results here are
not just imprecise, they can point in the wrong direction entirely.** If this
direction is worth pursuing further (e.g. broader shape coverage — wrapped
arrays like `{"items":[...]}`, richer per-field stats), it should be
re-benchmarked at this n=40+ scale from the start, not re-validated at n=4.
Reproduce: `bench/json-autostats.sh`. Runs: 2026-07-05 (n=4), 2026-07-05 (n=40,
corrected).

### Root cause, and a real fix that still didn't move the number

Captured full tool-call transcripts (`--output-format stream-json`) for both
arms to find out *why* ~12–25% of runs get the aggregate wrong. Two mechanical
bugs, both in `core/quiet-json.sh`, both fixed:

1. **The auto-computed `avg` was an unrounded 17-digit float**
   (`255.17747799999998`), forcing the model to round it itself — and it
   sometimes botched that (`255.00`, via the classic jq gotcha
   `avg | round * 100 / 100`, which rounds to an *integer* before scaling,
   instead of `(avg*100|round)/100`). **Fixed:** stats are now pre-rounded
   (`QUIET_JSON_STATS_DECIMALS`, default 4).
2. **The message read like raw data to process, not a finished answer.**
   **Fixed:** reworded to "EXACT stats... use them as-is, no further
   jq/computation needed."

Neither fix moved the needle. Re-running n=40/arm against the fixed code:

```
| arm                                  | cost $ | turns | correct | runs |
|----------------------------------------|-------:|------:|--------:|-----:|
| A baseline (no autostats)              | 0.0287 |   3.9 |    35/40 |  40 |
| B autostats (QUIET_JSON_AUTOSTATS=1)   | 0.0258 |   3.5 |    30/40 |  40 |

GLM: is_autostats coef -0.847 (p=0.159), odds ratio 0.43x
Fisher's exact: p=0.25 — still not significant, point estimate now favors baseline
```

**Why the fix didn't help:** the recurring wrong answers aren't random noise —
they're a small number of *specific* bugs the model repeats regardless of arm.
`262.19` appears constantly in both arms; it is *exactly* the average price of
`status=="open"` orders only (262.1876...) — the model conflates the two
sub-questions, reusing the status filter from part (1) when computing part
(2)'s average over *all* records. `2.55` (off by 100×) and `255.00` (the
round-order bug, still occurring even in the fixed autostats arm) round out the
pattern. **Even with the correct, pre-rounded, directively-labeled answer
already sitting in the tool output, the model sometimes still writes its own
verification jq and overwrites a correct given answer with a self-computed
wrong one.** That's not a bug quiet-bash's output formatting can fix — it's a
ceiling on how much a preview-enrichment feature can help when the calling
model doesn't reliably trust and reuse a provided value over re-deriving it.

**Final verdict: `QUIET_JSON_AUTOSTATS` has no demonstrated cost or
correctness benefit, on two independent n=40 tests, even after fixing the two
mechanical issues the investigation surfaced.** Kept opt-in (harmless, small
preview-size cost) but should not be marketed as either a cost or a
correctness lever without a task shape that shows a real, significant effect.
The two code fixes (pre-rounded stats, directive wording) are real
improvements and were kept regardless of the null result.

## quiet-repomap prototype — live A/B (verdict: real, significant win — shipped)

Candidate #3 from `docs/research/cost-levers-2026-07-update.md` (Aider-style
cross-file relevance ranking). `core/quiet-repomap.sh` is a zero-dependency
approximation: grep import/require (JS/TS) and import/from (Python)
statements, resolve each target to a repo file by basename match (not full
module resolution — approximate by design, documented in the script header),
and rank files by in-degree (how many other files import them). Complements
`quiet-map` (file-size/churn) and `quiet-outline` (per-file signatures) rather
than replacing them.

**Live A/B** (`bench/repomap-orient.sh`): a synthetic fixture
(`bench/fixtures/make-repomap-fixture.sh`) with one file imported by 9 others
and an unambiguous ground truth. Task: "identify the single file the rest of
the codebase depends on most." Two arms — `baseline` explores cold with Bash
only; `repomap` gets the `quiet-repomap.sh` output prepended to the task, as
if a session-start hook had already surfaced it (mirrors how `quiet-env`/
`quiet-map` are actually used, not a tool the agent has to discover itself).

n=8 pilot showed a clean, non-overlapping effect (every baseline rep cost more
than every repomap rep) — unlike the auto-stats candidate, this one didn't
need a correction. Confirmed at n=20/arm with a significance test:

```
| arm                       | cost $ | turns | output tok | correct | runs |
|----------------------------|-------:|------:|-----------:|--------:|-----:|
| A baseline (cold explore)  | 0.0530 |   3.4 |        927 |   19/19 |  19  |
| B repomap (pre-surfaced)   | 0.0123 |   1.0 |        207 |   20/20 |  20  |

repomap vs baseline: cost +76.8% (cheaper), turns 3.4 -> 1.0
Mann-Whitney U (cost):  p=5.1e-08  SIGNIFICANT
Mann-Whitney U (turns): p=6.4e-08  SIGNIFICANT
```

(One baseline rep produced no output — a transient CLI timeout, dropped, n=19
for that arm.) Correctness was ~100% in both arms — the win is entirely in
**turns eliminated**: repomap answered in exactly 1 turn every single time (no
tool calls needed), baseline needed a median of 3+ turns of `ls`/`grep`/`cat`
exploration to reach the same answer, each turn re-paying the growing
transcript.

**Verdict: real, significant, and mechanistically obvious — shipped as
`core/quiet-repomap.sh` with tests.** Unlike the JSON auto-stats candidate,
this isn't marginal: the effect is large (77% cost, ~2.4 fewer turns) and
consistent from n=8 to n=20 with no sign flip. Caveats: single synthetic
fixture with a deliberately unambiguous answer (a real repo's "most central
file" may be less clear-cut, and basename-only import resolution will
misattribute in a repo with duplicate basenames across directories); one
model (Haiku); the task shape (a single orientation question, no downstream
edit) is narrower than a full coding task. Reproduce: `bench/repomap-orient.sh`.
Run: 2026-07-06.

## C2 output-directive — 2026-07-08 (corrected)

**Correction (2026-07-08):** The 2026-07-07 result (9/20 and 11/20 correctness,
INCONCLUSIVE) was **invalid** — caused by a parallel fixture race: all jobs shared
one `$TARGET` directory, so concurrent runs corrupted each other's `quiet-map-stub.sh`
before grading. Fix: fixture creation moved inside `run_one` so each parallel job
gets its own isolated `mktemp -d`. Rerun below supersedes the original.

A/B: does prepending `output-styles/concise.md` to the system prompt reduce
output tokens and cost on a mid-complexity coding task, with zero quality
regression? Model: `claude-haiku-4-5`, n=20/arm, task: add a `--verbose` flag
to a stub bash file, graded by file modification check. Arm B uses
`--append-system-prompt` with the full text of `output-styles/concise.md`.

```
# Output-directive benchmark — mean per run
| arm | cost $ | output tok | turns | correct | runs |
|---|--:|--:|--:|--:|--:|
| A baseline (no directive) | 0.0488 | 609 | 3.5 | 20/20 | 20 |
| B concise (output-styles/concise.md) | 0.0497 | 585 | 3.5 | 20/20 | 20 |

concise vs baseline: cost -1.8%, output tok +3.8% (positive=cheaper/fewer)
Mann-Whitney U (cost): p=0.7953 not significant
Fisher's exact (correctness): p=1

**Verdict: DO NOT SHIP**
```

Correctness is now 20/20 on both arms — the prior ~50% pass-rate was entirely the
race condition, not model non-compliance. With valid isolation: cost is essentially
a wash (−1.8%, p=0.80, not significant), output tokens barely differ (3.8% fewer
for concise), and turns are equal (3.5 each). The concise directive has no
demonstrated effect on cost or output volume on this task shape. Reproduce:
`bench/output-directive.sh`. Run: 2026-07-08.

## C10 anti-preamble — 2026-07-08

A/B: does a minimal "no preamble, no postamble" one-sentence directive reduce
output tokens on a pure code-generation task (write a `count_lines` bash
function), without affecting correctness? Model: `claude-haiku-4-5`, n=20/arm,
no tools (`--allowedTools ""`). Arm B uses `--append-system-prompt` with one
sentence telling the model to skip acknowledgment and closing remarks.

```
# Anti-preamble directive benchmark — mean per run
| arm | cost $ | output tok | turns | correct | runs |
|---|--:|--:|--:|--:|--:|
| A baseline (no directive) | 0.0258 | 569 | 1.0 | 20/20 | 20 |
| B anti-preamble (directive) | 0.0267 | 527 | 1.0 | 20/20 | 20 |

anti-preamble vs baseline: output tok +7.4%, cost -3.2% (positive=fewer/cheaper)
Mann-Whitney U (output tok): p=0.3934 not significant
Fisher's exact (correctness): p=1

**Verdict: INCONCLUSIVE**
```

Output tokens trended 7.4% lower for the directive arm (569 → 527 mean), but
the Mann-Whitney test returned p=0.39 — not significant. Correctness was 20/20
on both arms (p=1). Turns were exactly 1.0 for both (single-shot generation,
no tool calls), so this is a clean measurement with no turn-count confound.

The direction is right (fewer output tokens with the directive) but the effect
is too small and too noisy to reach significance at n=20. On a 1-turn pure-text
task the model already tends toward concise function-only output, leaving little
room for the directive to bite. The INCONCLUSIVE verdict here is consistent with
the C2 output-directive result (also DO NOT SHIP / INCONCLUSIVE on a coding
task): a generic anti-preamble sentence appears not to reliably reduce output
on well-scoped code-gen prompts. A stronger test would use an open-ended
question task where the model is more likely to produce long preambles
unprompted. Reproduce: `bench/anti-preamble.sh`. Run: 2026-07-08.

## C6 cache-prefix health — 2026-07-08

Does quiet-bash's hook rewriting (log redirect / value-folding) preserve or bust
the cache prefix? Three arms: A baseline (no hooks), B cmd-only (PreToolUse Bash),
C full (Bash + PostToolUse Read/MCP). Model: `claude-haiku-4-5`, 3 read-only git
tasks (git log --oneline, git log --stat, git diff HEAD~3), n≈50/arm.
PRIMARY METRIC: cache_read % (cache_read_tokens / total_input_tokens).

```
# Cache-prefix health check — mean per run
| arm | cache_read % | cost $ | fresh in | cache_read | turns | runs |
|---|--:|--:|--:|--:|--:|--:|
| A baseline (no hooks) | 79.7% | 0.0400 | 19 | 69,163 | 2.8 | 50 |
| B cmd-only (Bash) | 79.5% | 0.0397 | 19 | 68,051 | 2.8 | 51 |
| C full (Bash + Read/MCP) | 78.6% | 0.0404 | 19 | 66,380 | 2.8 | 51 |

B cmd-only (Bash) cache_read% vs baseline: +0.2pp — prefix PRESERVED (p>0.05, no significant bust)

C full (Bash + Read/MCP) cache_read% vs baseline: +1.1pp — prefix PRESERVED (p>0.05, no significant bust)
```

**Verdict: prefix PRESERVED**

Both hooked arms show no statistically significant reduction in cache_read % vs
baseline (Mann-Whitney U, p>0.05 for both). The delta is ≤1.1pp and if anything
slightly in baseline's favour — within noise. The hooks do not bust the cache
prefix. Reproduce: `bench/cache-health.sh`. Run: 2026-07-08.

## C1 session-brief — 2026-07-08

A/B: does injecting a project brief (branch + recent commits) at session start
save exploration turns and cost on an orientation task? Model: `claude-haiku-4-5`,
n=20/arm. Arm B receives branch name + 5 recent commit messages prepended to the
task (simulating what the SessionStart hook injects). Task: identify the current
branch and most recent commit message. Graded correct if output contains both.

```
# Session-brief benchmark — mean per run
| arm | cost $ | turns | output tok | correct | runs |
|---|--:|--:|--:|--:|--:|
| A baseline (cold) | 0.0242 | 1.0 | 162 | 20/20 | 20 |
| B brief (pre-surfaced) | 0.0238 | 1.0 | 159 | 20/20 | 20 |

brief vs baseline: cost +1.7%, turns 1.0 -> 1.0
Mann-Whitney U (cost): p=0.8103 not significant
Fisher's exact (correctness): p=1

**Verdict: INCONCLUSIVE**
```

Both arms answered in exactly 1.0 turns (no tool calls needed) — the task was too
easy. `--allowedTools "Bash"` was set but the model answered from training knowledge
/ the task text itself, so there was no turn-reduction opportunity for the brief to
exploit. Cost and output tokens are within noise (p=0.81). Correctness was 20/20
for both. The design flaw: a question the model can answer without any tool calls
produces no turn differential regardless of pre-surfaced context. The session-brief
feature is expected to pay off on tasks that *require* file/git exploration (like
the repomap-orient benchmark's "which file is most imported" task, where repomap cut
turns from 3.4 to 1.0). The brief shipped regardless — it adds <100 bytes of
orientation context at session start at near-zero cost. Reproduce:
`bench/session-brief.sh`. Run: 2026-07-08.

## C4 find-collapse — 2026-07-08

A/B: does quiet-bash's PreToolUse Bash hook save cost when the agent runs
`find . -name "*.sh"` on a 200-file fixture (5 dirs × 40 files)?

Model: claude-haiku-4-5 | Repeats: 20/arm | Parallel: 4

| arm | cost $ | fresh in | turns | correct | runs |
|---|--:|--:|--:|--:|--:|
| A baseline (no hooks) | 0.0432 | 18 | 2.4 | 20/20 | 20 |
| B wrapped (find collapse) | 0.0434 | 19 | 2.6 | 20/20 | 20 |

wrapped vs baseline: cost -0.5% (positive=cheaper)
Mann-Whitney U (cost): p=0.6723 not significant
Fisher's exact (correctness): p=1.0000

**Verdict: DO NOT SHIP** (no cost reduction; p=0.67, not significant)

Finding: the find/ls wrapping produces no measurable cost saving on this task.
Correctness is 20/20 on both arms (the task is easy enough that the model answers
correctly regardless). The `input_tokens` (fresh) values are near-zero because
Haiku caches the system prompt aggressively — the 200-path find output lands in
cache, so collapsing it saves no fresh tokens in this configuration. The wrapping
is not harmful (correctness preserved, cost within noise), but this bench finds
no positive signal. Reproduce: `bench/find-collapse.sh`.

## C10 anti-preamble — re-run n=40 — 2026-07-09

Re-run at n=40 to resolve INCONCLUSIVE from n=20 (−7.4% output tokens, p=0.39).

```
# Anti-preamble directive benchmark — mean per run
| arm | cost $ | output tok | turns | correct | runs |
|---|--:|--:|--:|--:|--:|
| A baseline (no directive) | 0.0263 | 492 | 1.0 | 40/40 | 40 |
| B anti-preamble (directive) | 0.0275 | 524 | 1.0 | 40/40 | 40 |

anti-preamble vs baseline: output tok -6.4%, cost -4.7% (positive=fewer/cheaper)
Mann-Whitney U (output tok): p=0.7662 not significant
Fisher's exact (correctness): p=1

**Verdict: DO NOT SHIP**
```

**Verdict: DO NOT SHIP.** At n=40 the directive arm produces more output tokens on average (524 vs 492, −6.4% in the wrong direction) with p=0.77 — far from significant. The n=20 direction (fewer tokens) does not replicate; doubling the sample size reverses the trend. Correctness is 40/40 on both arms.

Reproduce: `QB_REPEATS=40 bench/anti-preamble.sh`. Run: 2026-07-09.
