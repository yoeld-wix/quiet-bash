# Context enrichment — design spec

**Status:** design spec
**Date:** 2026-06-28
**Research:** `docs/superpowers/research/2026-06-28-context-enrichment-candidates.md`
**Approved tranche:** `quiet-env` + `quiet-map` + `bench/enrichment.sh`.

Two one-shot deterministic "enrichment" verbs the agent runs to orient itself
without exploring/probing, plus a benchmark that measures the cost/time savings.
Invariant: **mechanical, lossless, no extra LLM call, no regression, zero-dependency**
(bash + coreutils + git + jq; bench report uses python3 like the existing one).

**Dropped (researched, not built):** MCP-servers / skills enrichment — the harness
already lists both in the agent's system prompt (redundant + less accurate than the
live view). Symbol/repo-map — deferred again (a def-index that misses a def is
worse than a search).

**Design rule:** one-shot CLI verbs the agent *runs* — NOT auto-injected artifacts
(injection re-bills every turn, goes stale, no hook surface).

---

## 1. `quiet-env` — environment / capability digest

### Problem
The agent discovers its environment by probing — `node -v`, `python --version`,
`which docker`, guessing npm-vs-pnpm — each a model round-trip (cost) and a serial
wait (time), and wrong guesses cause `command not found` / wrong-tool failures.

### Mechanism
`core/quiet-env.sh` (no args → full digest; the parts the harness does NOT provide).
Compact sections, each prefixed `[quiet-env]`:
- **Package manager** (highest-value): from lockfiles in cwd, most-specific wins —
  JS: `pnpm-lock.yaml`→pnpm, `yarn.lock`→yarn, `bun.lockb`→bun, `package-lock.json`→npm;
  Python: `poetry.lock`→poetry, `uv.lock`→uv, `Pipfile.lock`→pipenv, `requirements.txt`→pip.
  Report each detected (a repo can have both JS + Python).
- **Runtimes, present-only**: for node/python3/go/rustc/java/ruby/deno/bun that
  exist (`command -v`), print version using the correct flag (`go version`;
  `java -version` writes stderr → `2>&1`; `python3 --version`).
- **Installed CLIs**: `command -v` sweep over a relevant set (git rg jq fd gh
  docker kubectl make cargo curl tree) → list the present ones.
- **Ecosystem markers**: which of package.json/pyproject.toml/go.mod/Cargo.toml/
  Gemfile/pom.xml exist → project type(s).
- **Platform**: `uname -s`/`uname -m`, shell basename, CPU count
  (`getconf _NPROCESSORS_ONLN` → `sysctl -n hw.ncpu` → `?`).

### No-regression floor
Read-only; no installs. Only reports what's actually present (no false claims).
Version staleness under nvm/asdf is inherent to any snapshot — acceptable for
orientation. Portability: BSD/GNU differences handled per the flags above.

---

## 2. `quiet-map` — folder / repo map

### Problem
The agent runs `ls`/`find` and reads files to orient (which files are big? where's
the active code?) — navigation is the dominant agent-error class.

### Mechanism
`core/quiet-map.sh [--churn|--tree]`. Portable, gitignore-aware spine: file list
from `git ls-files -z` (in a repo) else `find . -type f -not -path './.git/*' -print0`;
text-filtered via `grep -Il .` (so binaries aren't line-counted). **No `find -printf`**
(absent on BSD).
- **default — size + context-risk** (the file-size-tree example): files by line
  count, biggest first, top `QUIET_MAP_TOP` (25), flagging files over
  `QUIET_MAP_BIG_LINES` (800) with `⚠` and the hint "prefer quiet-outline / Read
  with offset". Turns "here are sizes" into "here's what NOT to Read whole".
- **`--churn`** (git only): most-changed files —
  `git log --format= --name-only -n <QUIET_MAP_CHURN_COMMITS:-500> | sed '/^$/d' | sort | uniq -c | sort -rn | head`.
  Info the filesystem can't give. Not a git repo → stderr + exit 2.
- **`--tree`**: structure digest — files-per-top-level-dir, sorted.
- Unknown flag / no text files → handled (exit 2 / informational exit 0).

### No-regression floor
Read-only; never mutates. Lossless orientation aid — it points at files, never
replaces reading them. Honest header text (it's a *map*, not the content).

---

## 3. `bench/enrichment.sh` — measure the savings

Mirror the existing `bench/model-economy.*` trio (which ships with canned-data
unit tests, no live model in CI).

- **`bench/enrichment-tasks.sh`** — N (8–12) code-localization tasks over a target
  repo: prompt + an index-aligned regex assertion; a `fm_grade <i> <answer>` grader
  (pass/fail; out-of-range index → fail, no silent pass) — same shape as `me_grade`.
- **`bench/enrichment.sh`** — runner: for each arm × task × repeat, prepend the arm's
  map (control = none; `map` = `quiet-env` + `quiet-map` output capped ~1k tokens;
  optional `symbol`), invoke `claude -p --output-format json`, emit one JSONL row
  per run with input/output tokens, `total_cost_usd`, `duration_ms`, `num_turns`,
  pass. Env knobs `FM_TARGET/FM_MODEL/FM_ARMS/FM_REPEATS/FM_BUDGET`.
- **`bench/enrichment-report.py`** — read JSONL → per-arm cost, wall-clock, turns,
  pass-rate; **gate verdict at equal pass-rate** (report regression if pass-rate
  drops); print deltas vs control. Honest framing: expect a win mainly on
  weak-model + large-repo.

### Testing (no live model in CI)
Unit-test `fm_grade` (correct→pass, wrong→fail, out-of-range→fail, prompts/asserts
aligned) and `enrichment-report.py` (canned JSONL → correct deltas + zero-regression
verdict + a pass-rate-drop → regression verdict) — exactly how `model-economy` is
tested in `tests/run.sh`.

---

## Cross-cutting
- **Surface:** README "what it covers" row (orientation/enrichment); a
  `deterministic-first` SKILL.md row ("orient with `quiet-env`/`quiet-map` before
  exploring/probing"). Keep existing headings + verb references intact.
- **Tests** (`tests/run.sh`): `quiet-env` (runs, reports present runtimes, detects a
  pkg manager from a fixture lockfile, platform line); `quiet-map` (size map flags a
  big fixture file; `--churn` runs in-repo; `--tree`; unknown flag → exit 2; non-git
  `--churn` → exit 2); bench grader + report unit tests (canned data).
- **Tasks:** quiet-env; quiet-map; the bench trio; docs/surface. Independent enough
  to sequence; bench is the integration-heavy one (mirror model-economy — read it).

## Open questions (resolved)
- quiet-env: default = full digest (no mode flags in v1).
- quiet-map big-file threshold: 800 lines (`QUIET_MAP_BIG_LINES`).
- bench arms v1: control + map (+ optional symbol behind a flag).
