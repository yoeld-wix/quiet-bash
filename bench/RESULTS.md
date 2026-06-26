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

High run-to-run variance (agent behaviour varies): input ~8% is the steadier estimate; cost 6–15% is noisy. Short-task A/B (bench/agentic.sh) was ~flat — fixed overhead dominates. Numbers are post-v1.22.1 (the fix that made the rewrite actually apply).

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
