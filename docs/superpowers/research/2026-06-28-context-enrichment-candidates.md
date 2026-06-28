# Deterministic context enrichment — candidates + experiment design

**Date:** 2026-06-28
**Question:** What deterministic artifacts can we compute over a **folder** and the
**environment** so an agent stops *discovering* (exploring files, probing for
tools, guessing the package manager) — cutting token cost AND wall-clock time?
**Method:** three parallel sweeps — folder-map candidates, environment/capability
candidates, prior art + experiment design. Raw:
`.superpowers/research/{folder-maps-candidates,env-enrichment-candidates,folder-maps-priorart-experiment}.md`.

Invariant: **mechanical, lossless, no extra LLM call, no regression, zero-dependency**
(bash + coreutils + git + jq).

---

## Why this saves cost AND time

Agents are **weak navigators** (research: navigation is ~31% of agent errors vs
~9% tool-use). They burn turns running `ls`/`find`, reading files to orient, and
probing `node -v` / `which docker` / guessing npm-vs-pnpm — each a model
round-trip (cost) and a serial wait (time). A one-shot deterministic scan hands
all of it over once. Biggest headroom is **weak models on large repos**; expect
flat/negative on strong-model + tiny-repo (the ceiling effect we already hit).

**Design rule (from the research):** ship as **one-shot CLI verbs the agent runs**
(`quiet-map`, `quiet-env`), NOT an auto-injected artifact — injection re-bills
unrequested tokens every turn, goes stale, and has no hook surface (fails the
invariant). MCP-servers and skills enrichment are **explicitly dropped**: the
harness already lists both in the system prompt, so re-deriving them from disk is
redundant and *less* accurate (configured ≠ connected).

---

## Ranked candidates (all targets)

### Environment / capability — `quiet-env`

| # | Candidate | Net-new? | Value / Risk |
|---|---|---|---|
| E2 | **Package-manager detection** (npm/yarn/pnpm/bun, pip/poetry/uv via lockfile precedence) | yes | **High / Low** — kills the #1 wrong-tool failure (npm in a pnpm repo) |
| E1 | **Installed-CLI sweep** (`command -v` over git/rg/jq/fd/gh/docker/kubectl/make/cargo…) | yes | **High / V.Low** — prevents `command not found` round-trips |
| E3 | **Runtime versions, present-only** (node/python/go/rust/java/ruby/deno/bun) | yes | High / Low (nvm/asdf staleness) |
| E4 | Ecosystem markers (package.json/pyproject/go.mod/Cargo.toml → type) | yes | Med-High / V.Low |
| E6 | OS/arch/shell + CPU count (parallelism) | yes | Med / V.Low |
| E7/E8 | MCP servers / skills | **no — DROP** | ~0 — harness already provides, redundant + less accurate |

### Folder / repo — `quiet-map`

| # | Candidate | Value / Risk |
|---|---|---|
| C6 | **Churn / hotspot map** (most-changed files: `git log --name-only \| sort \| uniq -c`) | **High / V.Low** — info the filesystem *cannot* give (where the live code is) |
| C1+C7 | **Size + context-risk map** (files/dirs by line count, biggest-first, flagging "too big to Read whole → use quiet-outline/offset") — *the file-size-tree example* | **High / V.Low** |
| C2 | Structure digest (depth-capped, entry-counted, gitignore-aware tree via `git ls-files`) | Med-High / V.Low |
| C5 | Where-things-live (scripts/configs/test dirs) — overlaps E-side; fold in once | Med-High / Low |
| C3 | Language/LOC breakdown | Low-Med / V.Low — fold in as a header |
| C4 | Symbol / repo-map (def index) | High potential / **Med** — **DEFER again** (a def-index that misses a def is worse than a search; only as grep-shaped `file:line:sig` with no "complete" claim) |

**Portability landmines (verified on macOS):** BSD `find` has **no `-printf`**;
`nproc` is GNU-only (use `getconf _NPROCESSORS_ONLN`); `go version` not
`--version`; `java -version` → stderr; `python` ≠ `python3`; `wc -l` counts
binaries (filter with `git ls-files | grep -Il .`). The portable spine for every
folder map is **`git ls-files | grep -Il . | xargs wc -l`** (full repo map in
~0.02s, gitignore-aware).

---

## Recommended tranche (for approval)

Two one-shot verbs + the measurement bench. All net-new, low-risk, zero-dep.

1. **`quiet-env`** (default output fuses **E2 + E1 + E3 + E4 + E6**) — the
   environment facts the harness does *not* provide and the agent otherwise
   probes for. Directly answers your "node version / which programs exist".
2. **`quiet-map`** (default = **C1+C7** size + context-risk; `--churn` = **C6**;
   `--tree` = **C2**) — the folder side; your file-size-tree-map example is the
   default mode, made useful by the "don't Read these whole" overlay.
3. **`bench/enrichment.sh`** — the measurement harness (below), so the savings are
   measured, not assumed.

**Dropped:** E7/E8 (MCP/skills — redundant), C4 (repo-map — deferred again).

---

## Experiment design (the measurement half)

Mirror `bench/model-economy.sh` conventions; zero-dep (maps built from
git+coreutils; only the report needs python3).

- **Task:** code-localization — "which file implements / would you edit for X?"
  over a real external repo; regex-graded ground truth (reuse `me_grade`). 8–12
  tasks (avoid the 1-of-30 small-repo ceiling).
- **Arms:** `control` (no map) · `map` (`quiet-map` + `quiet-env` output prepended,
  capped ~1k tokens) · optional `symbol-map` (adds a grep-shaped signature index).
- **Metrics (directly observable** from `claude -p --output-format json`): input/
  output tokens, `total_cost_usd`, `duration_ms` (wall-clock), `num_turns`,
  regex correctness. **Needs instrumentation:** per-tool Read/Grep/Glob counts via
  `stream-json` or a PostToolUse counter. **Endpoint: cost + wall-clock at equal
  pass-rate.**
- **Beat the ceiling effect:** mandatory **weak-model arm** (largest navigation
  headroom) + a strong-model contrast; larger repo; `FM_REPEATS>=5` with reported
  variance; control run-order/cache state.
- **Honest expected result:** flat/negative on strong-model+small-repo; real win
  on weak-model+large-repo (~10–25% regime). "Helps weak models on big repos, not
  strong models on small ones" is the clean, publishable finding (tells users when
  to enable it) — and avoids over-claiming, per repo norms.

---

## Implementation note
`quiet-env` + `quiet-map` go through spec → plan → subagent-driven build on this
branch. The bench can land in the same tranche or as a fast follow (it measures
rather than implements). Prior-art citations (Aider repo-map, Continue repo map,
Cursor indexing, "Weak Navigators") are in the raw experiment file.
