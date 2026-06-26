# Deterministic-first: shifting find/aggregate/verify work from the model to the shell

**Status:** design / research spec
**Date:** 2026-06-26
**Topic:** A quiet-bash lever that changes *what the agent decides to do* — pushing
finding, counting, extracting, parsing, verifying, repeating, and waiting onto
deterministic shell pipelines instead of having the model do that work by reading
content into its context window.

---

## 1. Problem

quiet-bash today is **reactive output compression**. The agent decides what to do,
produces bulky output, and a hook shrinks it *after the fact* — losslessly, with no
model cooperation required (`core/quiet-core.sh`). Crucially, `quiet_rewrite`
*deliberately refuses* to touch `grep`/`rg`/`find` searches, because "a targeted
search missing a match is a regression" (`core/quiet-core.sh:312`).

That leaves a whole class of waste untouched — waste that happens **before** any
output is produced, in the model's *choice of approach*:

- The model **reads** 20 files to answer "which ones import `X`?" instead of
  `rg -l X`.
- It pulls a 10k-line log into context to answer "did it pass / how many errors?"
  instead of `grep -c`.
- It copies field values out of a large JSON blob by eye instead of `jq`.
- It re-reads the same data across several turns to re-count or re-extract.
- It "loops" by issuing N near-identical tool calls instead of one `for`/`xargs`.
- It polls by reading status repeatedly instead of an `until` loop that blocks
  until the condition is true.

A human doesn't read a 10k-line log into their head; they pipe
`grep | sort | uniq -c`. The deterministic shell is **cheaper** (no tokens for the
content, no tokens to re-send it every later turn) and **more correct** (a count
from `uniq -c` doesn't hallucinate; a regex match doesn't skim past line 4,000).

**Goal:** give the agent a *deterministic-first reflex* — when the task is
find / count / extract / parse / verify / repeat / wait, express it as a shell
pipeline whose *answer* enters context, not the *haystack*.

### Non-goals

- Not replacing quiet-bash's reactive compression — this **stacks** on top of it,
  targeting a different token category (the content the model *chooses to ingest*,
  vs. the output a command *happens to emit*).
- Not a general "write better bash" tutor. Scope is strictly the
  read-to-answer → pipe-to-answer shift.
- Not model routing, prompt compression, or anything that trades away quality
  (those are out of scope per `docs/maximizing-savings.md` "honest ceiling").

---

## 2. The governing constraint (why the mechanism is the hard part)

quiet-bash has one invariant that everything else bends to:
**mechanical, lossless-or-byte-exact-recoverable, no extra LLM call, and no
regression in result quality** (`docs/token-reduction-research.md`).

The interception axis collides with this directly. The reactive hook can safely
rewrite *output* because the full payload is spilled byte-exact to disk — nothing
is lost. But rewriting an *action* ("read these 20 files" → "`rg -l X`") is **not
lossless**: the two do not return the same information, and if the model needed
something the pipeline didn't surface, that's a silent regression — exactly the
reason grep is left untouched today.

This is the load-bearing finding of the research: **the shift can be safely
*encouraged* but not safely *forced by rewrite*.** It splits the mechanism space
cleanly:

- Mechanisms that keep the model in control of the final action (a skill; a
  *non-blocking* advisory; an opt-in helper command the model chooses to call) →
  lossless by construction, zero regression risk.
- Mechanisms that replace the model's action deterministically (rewrite a Read
  into a grep) → violate the invariant. **Ruled out.**

---

## 3. Approaches considered

### A — Skill-led reflex  ⭐ recommended core

A new skill, sibling to `minimal-change`, that codifies the decision rule and a
pattern cheatsheet. The model stays in control; the skill changes its *default
reach*.

- **Pros:** zero regression risk (lossless by construction — the model still
  decides), matches existing in-repo precedent (`skills/minimal-change`),
  cross-agent (skills load on all 8 supported agents), no fragile intent
  detection.
- **Cons:** soft — depends on the model honoring it; savings are real but
  workload-dependent and harder to headline-measure than a mechanical hook.

### B — Hook-led advisory

Extend the PreToolUse path to *detect* "about to read-to-find" patterns and emit a
**non-blocking tip**, never a rewrite.

- **Pros:** active; fits `hooks.json`; catches cases the model forgets.
- **Cons:** intent is hard to infer deterministically (a `cat` may be a
  find-by-eye or a legitimate full read — the hook can't tell), so it is
  inherently noisy → false-positive fatigue. The PreToolUse Bash hook sees the
  *command string* but not *why*; the `Read` tool isn't even on the Bash matcher.
  **Rewriting** here would breach the no-regression invariant. Viable only as
  advisory, and even then its precision is low.

### C — Deterministic verb tools

A tiny vocabulary of `quiet-*` verbs that wrap the gnarly pipeline ergonomics, so
the agent reaches for one obvious command instead of reading.

- **Pros:** lowers the activation energy that makes agents read instead of pipe;
  deterministic; composes with the existing `quiet-query` over spilled files.
- **Cons:** new surface to maintain; still needs the skill to drive adoption;
  risks being "a worse grep" if it wraps what's already ergonomic.

### Recommendation

**A as the core + a minimal C as a backstop; B analyzed and bounded to advisory
only.**

- **A** is the only mechanism that preserves the invariant unconditionally, and it
  reuses a precedent that already exists in the repo. It is the spine.
- **C** earns its place *only* for the 2–3 pipelines whose ergonomics are the real
  reason agents avoid them (verify-over-spill, aggregate-with-spill, structured
  extract). We do **not** wrap `rg`/`grep` — they're already ergonomic; a wrapper
  would be strictly worse and add maintenance for nothing.
- **B** ships *later, if at all*, and only as a non-blocking tip behind a config
  flag, because its precision is low. The spec documents the regression boundary
  so a future contributor doesn't "upgrade" it into a rewrite.

---

## 4. Design

### 4.1 Component A — the `deterministic-first` skill

Location: `skills/deterministic-first/SKILL.md` (mirrors `skills/minimal-change/`).

**Frontmatter `description`** (the load-bearing trigger — written so the agent
self-selects it): *"Use before reading files or large output to find, count,
extract, parse, verify, loop, or wait. Routes that work to a deterministic shell
pipeline so the answer enters context, not the haystack — cheaper and more correct
than reading content into the model."*

**Body structure** (kept short and scannable, like `minimal-change`):

1. **One-line framing** — quiet-bash's hooks shrink output you already chose to
   read; this shifts the *choice*: don't read the haystack to find the needle,
   pipe for the needle.

2. **The decision rule.** Before issuing a Read / `cat` / large fetch *whose
   purpose is to locate or compute something*, ask: *can a pipeline return just the
   answer?* If yes, run the pipeline.

3. **The pattern table** — task → deterministic form. Concrete and copy-pasteable:

   | Task | Read-to-answer (avoid) | Deterministic form |
   |---|---|---|
   | **Find** which files / where | open files until you spot it | `rg -l PAT` · `rg -n PAT` · `grep -rln` |
   | **Count** / frequency | read log, tally by eye | `grep -c PAT` · `… \| sort \| uniq -c \| sort -rn` |
   | **Extract** fields | copy values out of JSON/text | `jq '.path'` · `awk '{print $2}'` · `grep -oE` |
   | **Parse** structured slices | scan a config visually | `jq` / `yq` / `quiet-query` over the spill |
   | **Verify** a fact | read output to confirm | `grep -q && echo OK` · `test -f` · exit-code check |
   | **Repeat** over a set | N near-identical tool calls | `xargs` · `for f in …; do …; done` |
   | **Wait** for a condition | poll by re-reading status | `until COND; do sleep N; done` |

4. **Composition with quiet-bash.** When the haystack is a spilled quiet-bash log
   (`[ok: … hidden in <path>]`), the deterministic form runs *against that file* —
   `grep`/`jq`/`quiet-query <path>` — so the answer is recovered without re-reading.
   This is the explicit bridge between the reactive layer and this one.

5. **The no-regression floor (mirrors `minimal-change`'s).** Never trade
   correctness for a pipeline: if you genuinely need the full content (reviewing
   prose, understanding unfamiliar code, anything where *you* are the right
   judge), **read it** — a pipeline that misses the thing you needed costs far more
   than it saves. The reflex is for *find/compute*, not for *understand*. When a
   pattern might miss matches (case, word boundaries, multiline), widen it or fall
   back to reading.

**Why a skill and not a prompt injection:** skills are model-selected and
cross-agent; injecting this into every turn's context would re-bill the guidance
each turn — the opposite of the goal. (The `quiet-prompt` machinery already exists
precisely to keep injected prompts out of the per-turn bill.)

### 4.2 Component C — minimal deterministic verbs

Ship in `core/`, mirroring `quiet-query.sh`. Only verbs that clear the bar
*"the pipeline is gnarly enough that agents avoid it and read instead."* Initial
set — to be cut further if any one fails that test during implementation:

- **`quiet-verify`** — `quiet-verify <file> <pattern>` → prints `OK`/`FAIL` + the
  match count, exit code reflects it. Wraps the
  `grep -c; if … then echo OK` dance the model otherwise reads a log to do.
- **`quiet-agg`** — `quiet-agg <file> <regex>` → top-N frequency table
  (`grep -oE | sort | uniq -c | sort -rn | head`). The single most common "I'll
  just read it and tally" case.

We **deliberately ship no** `quiet-find` / `quiet-extract`: `rg` and `jq` are
already ergonomic and `quiet-query` already covers structured spill access. Adding
wrappers there would be "a worse grep." The skill points at the *real* tools for
those.

Each verb: zero-dependency `bash` (+ `jq` only where already required), prints a
one-line provenance header so its output is self-describing in the transcript, and
operates on a path (typically a quiet-bash spill) — never swallowing data.

### 4.3 Component B — advisory hook (deferred, bounded)

Documented but **not shipped in v1**. If pursued: a PostToolUse observation that,
on detecting a high-confidence read-to-find signal (e.g. ≥3 sequential `Read`s of
the same directory in a window), appends a single non-blocking line: *"tip:
`rg -l PAT <dir>` answers this in one call."* Hard rules for any future
implementer:

- **Never rewrite an action.** Advisory text only. (The regression boundary in §2.)
- Behind a config flag, default **off**, because precision is low.
- One tip per cluster, rate-limited — false positives must not nag.

---

## 5. Data flow

```
agent forms intent ("which files import X?" / "did tests pass?")
        │
        ▼
 [deterministic-first skill]  ── changes default reach ──►  shell pipeline
        │                                                        │
        │ (haystack already a quiet-bash spill?)                 ▼
        └────────────► rg/jq/grep/quiet-query/quiet-* ──►  ANSWER enters context
                                                           (haystack never read)
```

The reactive layer (existing hooks) and this proactive layer compose: reactive
keeps the haystack *out* if it's emitted; deterministic-first keeps the model from
*choosing to ingest* it in the first place. Different token categories →
additive, like the stack in `docs/maximizing-savings.md`.

---

## 6. Testing & measurement

**Skill correctness** is mostly a prompt-quality question, so the measurable
surface is the verbs and the composition claims:

- **Verb unit tests** (`tests/`, matching the repo's existing bash-test style):
  `quiet-verify` returns correct OK/FAIL + count and exit code on hit/miss/empty;
  `quiet-agg` produces a correct frequency table and handles no-match, huge input,
  and binary-ish input without crashing. Zero-dependency assertions.
- **Composition test:** run a known-verbose command (so quiet-bash spills it),
  then assert the documented `grep`/`quiet-*` recovery returns the exact answer
  from the spill — proving the bridge in §4.1.5 actually holds.
- **Benchmark hook** (`bench/`): add a scenario pair — *read-to-answer* vs.
  *pipe-to-answer* on a real large log / JSON / file set from the existing bench
  corpus — reporting tokens-into-context for each. This is the honest number for
  the README; per repo norms (`docs/maximizing-savings.md`) it must be
  reproducible and not over-claimed. Expect a large per-instance cut on the
  targeted operations and a modest, workload-dependent session-level cut — state
  it that way, don't headline a session number the skill can't guarantee.

**No-regression check:** the skill's own floor (§4.1.5) is the guard; the bench
must include at least one "you should NOT pipe this" case (e.g. understand
unfamiliar code) to document where the reflex correctly does *not* apply.

---

## 7. Rollout

1. Skill `deterministic-first` + the two verbs + tests.
2. Wire the skill into the plugin manifest the same way `minimal-change` is wired;
   verbs are callable by path like `quiet-query.sh` (and referenced from the
   skill).
3. Bench scenario + a short `docs/` note, linked from the README "what it covers"
   table as a new (proactive) row, clearly distinguished from the reactive levers.
4. B (advisory hook) only after A+C show real adoption and we have a
   high-precision signal — otherwise it stays documented-but-unshipped.

---

## 8. Open questions for implementation

- Exact trigger wording of the skill `description` — it determines self-selection
  rate; worth A/B-style iteration against real transcripts.
- Whether `quiet-agg` should default to a fixed top-N or take a count arg (lean:
  fixed default, optional arg — match `quiet-query`'s ergonomics).
- Final verb set: start with two, cut to one if `quiet-agg` or `quiet-verify`
  doesn't clear the "agents actually avoid this pipeline" bar in practice.
