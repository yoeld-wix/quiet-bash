# Deterministic-first — round 2: re-validated + new candidates

**Date:** 2026-06-28
**Builds on:** `2026-06-28-deterministic-first-expansion-candidates.md` (round 1).
**Method:** two parallel sweeps — (a) deeper re-validation of the unshipped
round-1 candidates against the actual repo code, (b) a fresh hunt for *new*
candidates in categories round 1 skipped + fresh prior art. Raw outputs:
`.superpowers/research/round2-{revalidation,new-candidates}.md`.

**Shipped to date (excluded):** reactive output/JSON/result collapsing +
`quiet-query`; verbs `quiet-verify`, `quiet-agg`, `quiet-check`, `quiet-wait`;
duplicate-read dedup (PostToolUse Read hook).

---

## Re-validation of round-1 remainder

| # | Candidate | Verdict | Why |
|---|---|---|---|
| 4 | **Search-output collapse (grep/rg)** | **PICK** | Highest value-to-effort. Reuses the shipped `_quiet_wrap_search` heredoc (same spill+first-N+count+pointer as `find`/`ls -R`/`tree`); add as a **verbatim-command wrap**, so it sidesteps the search-semantics regression that made grep/rg carved-out. Lossless, ~2 matchers, no new file/hook. |
| 7 | **Memoized command cache (`quiet-cache`)** | DEFER | Net-new model-action shift (re-*runs*), but staleness nuance — only safe as an explicit opt-in verb with named-input keys + TTL + visible `cached @`. Its own project. |
| 8 | **Math/date/`tsort` skill rows** | **BUNDLE** | Doc-only, zero risk, real correctness win. Ride on a code PR (`bc`/`awk`/`date`/`tsort` all present). |
| 5 | Prompt-cache stable-prefix | **DROP** | Overstated — quiet-bash only tail-edits, so spill names / jq key order never perturb the cached prefix. Keep at most a `jq -S` rider. |
| 6 | Repo-map / symbol index | DEFER | Highest effort + genuine navigation-completeness regression risk (a map that misses a def is worse than a search); overlaps shipped `rg -l`/outline. |
| 9 | MCP tool-schema slimming | **DROP** | Tool-def layer is invisible to hooks; only viable as a README pointer to native `defer_loading`. |
| 10 | Retroactive cross-turn masking | **BLOCKED** | No hook surface edits prior turns; unmeasurable cache hazard. Its cache-safe slice already shipped as duplicate-read dedup. |

## New candidates (round-2 sweep)

| # | Candidate | Action today | Deterministic replacement | Value | Risk |
|---|---|---|---|---|---|
| N4 | **`quiet-conf FILE KEY`** | read a whole config/lockfile to get one value | resolve one scalar via `jq`/`grep` (dep version, test script, env var) | **High** | **Low** |
| N2 | **`quiet-patch` (apply a diff)** | re-emit a whole file to make a small edit | model emits a unified diff; `git apply` it → output cost scales with the *change* | **High** | Low-Med |
| N1 | **`quiet-applies` (diff pre-check)** | reason over two file versions to see if a patch fits | `git apply --check` → APPLIES / exact conflicting hunks | Med-High | Low |
| N3 | **`quiet-hist` / `quiet-blame`** | scroll full `git log`/`blame` dumps + read files | `git log -1` / `git blame -L` / `git log -S` (pickaxe) → exact answer | Med-High | Low |
| N5 | **`quiet-codec`** | base64 / url-encode / hash in-head (silently wrong) | `base64` / `jq @uri` / `shasum` | Med | Low |

Below the cut: N6 (CSV↔JSON via `jq @csv`), N7 (impacted-test selection — high
upside but real false-negative risk → advisory-only). Fresh 2024-26 prior art in
the raw file (Aider unified-diff format, Diff-XYZ/Base64Bench reliability gaps).

---

## Recommended NEXT tranche (for approval)

Pick the high-value / low-risk winners that ship cleanly on the existing verb +
reactive-wrap patterns; defer the bigger/standalone ones.

1. **N4 `quiet-conf`** — highest-frequency model action in the set (reading a
   100–10,000-line config/lockfile for one value); pure action-shift; `jq`-exact;
   distinct from `quiet-query` (which targets spills, not config read in full).
2. **#4 search-output collapse** — highest value-to-effort; reuses shipped
   `_quiet_wrap_search`; lossless verbatim-wrap; closes the long-standing grep/rg
   context-flood gap without the semantic-regression risk of a flag rewrite.
3. **N3 `quiet-hist` / `quiet-blame`** — exact git-archaeology answers; surfaces
   the pickaxe (`log -S`) models almost never reach for; low risk (git is ground
   truth, read-only).
4. **#8 math/date/`tsort`** — free doc bundle (skill cheatsheet rows).

**Deferred to a following round (each its own project):** **N2 `quiet-patch`** +
**N1 `quiet-applies`** (the biggest *output-side* lever — deserves a focused
design with a skill behavior-change), **#7 `quiet-cache`**, **#6 repo-map**.

**Dropped:** #5, #9, #10 (reasons above), N7 (false-negative risk).

If approved, the tranche goes through spec → plan → subagent-driven build, on the
current expansion branch (stacks on PR #6 to avoid conflicts in the shared
`tests/run.sh` / SKILL.md / README that #6 also edits).
