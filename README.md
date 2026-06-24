<p align="center">
  <img src="assets/logo.png" alt="quiet-bash" width="320">
</p>

<p align="center">
  <em>Stop paying to re-read build logs your agent already skimmed.</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/release-v1.16.2-1fb588" alt="release">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="license">
  <img src="https://img.shields.io/badge/works%20with-7%20agents-1fb588" alt="works with 7 agents">
  <img src="https://img.shields.io/badge/command%20output-−99.9%25-e8836b" alt="command output reduced 99.9%">
  <a href="https://github.com/yoeld-wix/quiet-bash/actions/workflows/ci.yml"><img src="https://github.com/yoeld-wix/quiet-bash/actions/workflows/ci.yml/badge.svg" alt="ci"></a>
</p>

<p align="center">
  <a href="#supported-agents">Works with Claude Code · Codex · Gemini · Copilot · Cursor · Aider · any shell</a> ·
  <a href="#how-much-it-saves">Savings</a> ·
  <a href="docs/token-savings-research.md">Research</a> ·
  <a href="docs/graph-options.md">Graph options</a> ·
  <a href="examples/before-after.md">Examples</a> ·
  <a href="LICENSE">MIT</a>
</p>

---

A hook (and universal shell wrapper) that keeps noisy command output out of an
AI coding agent's context window.

When the agent runs a known-verbose command — a test run, a build, a buildkite
invocation, a `docker build`, a `bazel build/test`, or a big `git diff` — the
full output is redirected to a temp log file and the agent only sees a short
summary. On failure it still gets the tail of the log (and a pointer to grep
the rest), so nothing important is lost — and that surfaced tail is cleaned
first: ANSI colors stripped, carriage-return progress bars collapsed to their
final state, and repeated lines folded to `(xN)`, so the failure preview stays
small and readable.

Short, quick commands are passed through untouched: wrapping them would cost
more in extra round-trips than it would save.

It does the same for **large reads**. A giant `package-lock.json` or a
3,000-line source file is collapsed to a structured preview — a value-folded
JSON/YAML summary, or a **signature outline** of the code (imports +
class/function/method signatures, bodies elided) — with the full content one
`jq` / `Read`-range away. Files the agent skims once then no longer get re-sent
in full on every later turn.

## How much it saves

> **Across 10 real commands on a production monorepo, raw output totaled
> `536,957` tokens. quiet-bash replaced them with `~250` tokens of summaries —
> a `99.9%` cut on the command output that reaches the model.**

<p align="center">
  <img src="assets/savings-compact.svg" alt="536,957 raw tokens become 250 summary tokens" width="820">
</p>

| | Without quiet-bash | With quiet-bash | Reduction |
|---|--:|--:|--:|
| Average verbose command | ~53,700 tok | ~25 tok | **99.95%** |
| All 10 commands (this benchmark) | 536,957 tok | 250 tok | **99.9%** |

<sub>10-subagent benchmark on a real monorepo — 5 commands run live, 5 modeled
from representative logs. Token estimate ≈ bytes ÷ 4. Methodology in
[Benchmark](#benchmark). Research notes in
[Token savings research](docs/token-savings-research.md).</sub>

> **Large reads collapse too.** A real 3,196-line Python source file
> (`~33,900` tok) becomes a `164`-symbol outline of `~2,700` tok — **−92%** —
> with every body one `Read offset=…` away. Large `*.json`/`*.yaml` reads fold
> the same way (a real `package-lock.json`: `~299,000` → `~660` tok, **−99.8%**).
> Like logs, a file the agent reads early is re-sent on every later turn, so
> these savings compound across the session too.

### Bottom line for an average dev

**≈ 30 % lower token cost on a typical session** — ranging from ~15–20 % for
read/edit-heavy work to **50 %+** for build- and test-heavy workflows. The rule
of thumb:

> total saving ≈ (share of your context that is command output) × 99 %

<p align="center">
  <img src="assets/workflow-context-stacks.svg" alt="Estimated session savings by workflow" width="820">
</p>

| Your workflow | Command output ≈ | Total token cost saved |
|---|--:|--:|
| Light (mostly reading/editing) | ~15–20 % of context | **~15–20 %** |
| Typical (regular test/build loops) | ~30–40 % | **~30 %** |
| Heavy (TDD, CI-debugging, full builds) | ~50–60 % | **~50 %+** |

The **99.9 %** cut on command output is measured. The session-level percentage
is a model — it depends on how log-heavy your work is, and prompt caching /
context compaction move it around — so treat ~30 % as a representative midpoint,
not a guarantee.

### Why it compounds over a session

An LLM agent is **stateless**: on *every* turn the whole conversation so far —
including all previous command output — is re-sent as input tokens. A log isn't
paid for once when it's produced; it's re-paid on every later turn it stays in
the context window.

So a 600-line `yarn test` dump near the start of a 40-step task isn't a one-time
cost — it's **~600 lines × every turn that follows**. quiet-bash turns that dump
into a single `[ok: exit 0 — 612 lines hidden in …]` line that never enters the
context, so you stop re-paying for it. Illustratively (assumptions below):

| Session | Verbose cmds | Log tokens re-sent **without** | **with** quiet-bash |
|---|--:|--:|--:|
| 10 turns | 4 | ~1.1M | ~500 |
| 25 turns | 10 | ~6.7M | ~3k |
| 40 turns | 16 | ~17.2M | ~8k |

<sub>Illustrative model: ~40% of turns run a verbose command, each resident for
~half the remaining session, avg ~53.7k tokens/log. Real numbers depend on how
log-heavy your work is — but the direction and order of magnitude hold.</sub>

It also **keeps the prompt-cache prefix stable** (fewer giant, varying tool
results → more context stays cached) and **preserves debuggability** — on
failure it still surfaces the last 40 lines inline, and small `git diff`/`show`/
`log` output is shown as normal.

## What it covers

| Command shape | Behaviour |
|---|---|
| **JS/TS:** `yarn`/`npm`/`pnpm`/`bun` (test/build/lint/install/add/ci/run/dev/start…), `npx …`, `jest`, `vitest`, `mocha`, `cypress`, `playwright`, `tsc`, `eslint`, `prettier`, `webpack`, `vite`, `rollup`, `esbuild`, `turbo`, `gulp`, `grunt` | Success → one summary line, output hidden. Failure → last 40 lines + log path. |
| **Python:** `pip install`, `pipenv`, `poetry`, `uv`, `conda`, `python -m …`, `python setup.py`, `pytest`, `tox`, `nox` | same |
| **JVM/Scala:** `gradle`/`gradlew`, `mvn`/`mvnw`/`maven`, `sbt`, `bloop`, `bazel`, `buildozer` | same |
| **Go / Rust / Ruby / C:** `go test/build/install/vet/mod/get/run`, `cargo`, `bundle`, `gem install`, `rake`, `rspec`, `make`, `cmake`, `ninja` | same |
| **Containers / CI:** `docker build`, `docker compose`/`docker-compose`, `bk`/`buildkite` | same |
| `git diff` / `git show` / `git log` (without a limiting flag, pipe, or redirect) | ≤60 lines → shown inline. Larger → `--stat`/`--oneline` summary + log path. Failure → tail. |
| **Large `*.json` / `*.yaml` reads** (`cat`/`bat`/`head`/`jq .`/`yq .` of a file > 25 KB) | Collapsed preview: repeated object/array shapes fold to `"N more of M, same shape"`, long strings truncated, + a `jq`/`yq` drill-in footer. File untouched on disk. |
| **Large source files** (`cat`/`Read` of a `.py`/`.ts`/`.go`/`.rs`/`.java`/`.rb`/`.c`/… file > 30 KB) | Signature outline: imports + class/function/method signatures with bodies elided, each with the exact line range to expand (`Read <file> offset=S limit=N`). File untouched on disk. < 3 symbols → falls back to head/tail. |
| everything else (`ls`, `cat`, `grep`, `git status`, `gh …`, …) | Passed through unchanged. |

Already-bounded commands (those with `--stat`, `--oneline`, a pipe to
`head`/`grep`/…, or a `>` redirect) are left alone, and the hook never
double-wraps its own output or a follow-up read of a log file.

### Reading large JSON & YAML

`cat`-ing a big `package-lock.json`, `openapi.json`, `pnpm-lock.yaml`, or a k8s
bundle dumps tens of thousands of tokens the agent mostly skims. quiet-bash
rewrites a large `*.json`/`*.yaml` read into a **collapsed preview** — repeated
object/array shapes fold to one sample plus `"N more of M, same shape"` (so keys
aren't repeated hundreds of times), long strings truncate, and a footer prints
the exact `jq`/`yq` to query the full file (untouched on disk). A real
`package-lock.json` went from **~299,000 tokens → ~660** (−99.8%); a 50-doc k8s
manifest bundle collapses to its first few docs + a count.

YAML is converted to JSON with the first available of **`ruby` → `python3`+PyYAML
→ `yq`** (Ruby ships `yaml`+`json` in its stdlib, so this works out of the box on
macOS and most CI); if none is present, YAML passes through untouched. Multi-doc
YAML becomes an array; comments are dropped in conversion (fine for a summary).

The collapsed-preview format was chosen over gron-flat and schema-only by an
A/B/C benchmark measuring **tokens *and* answer accuracy**: collapsed used the
fewest tokens, matched gron on accuracy, and produced **zero hallucinated
values** — when a value is elided, the agent correctly defers to the file rather
than guessing. (`schema-only` was disqualified: it can't compress objects keyed
by distinct names, so `package-lock.json` barely shrank.)

Pass-through is deliberate: small files, `jq`/`yq` **projections** (you already
narrowed it), and piped/redirected commands are never touched. Tune with
`QUIET_JSON_MIN_BYTES` (default 25000).

### Querying without re-reading (`quiet-query`)

Spilling is only half the win — the other half is making the spilled payload
**cheap to interrogate**. Every collapsed-preview footer points at
`core/quiet-query.sh`, a jq-backed tool with query + aggregation ops that each
return a small, focused answer (not a dump):

```
quiet-query <file> keys                      # keys + value-types
quiet-query <file> count  '.items'           # how many
quiet-query <file> sample '.items' 5         # first 5
quiet-query <file> pluck  '.items' '.id'     # project one field
quiet-query <file> select '.items' '.score > 0.8'   # filter
quiet-query <file> group  '.items' '.status' # count by field  (aggregate)
quiet-query <file> stats  '.items' '.price'  # count/min/max/sum/avg
quiet-query <file> search '<regex>'          # matching paths
```

Works on JSON and YAML (shared converter). The agent runs these through its own
Bash tool, so a 300 K-token result becomes a handful of tiny, targeted queries.

### Outlining large source files

Reading a 1,800-line module dumps thousands of tokens the agent mostly skims —
and because the transcript is re-sent every turn, that file is re-billed on every
later turn. quiet-bash rewrites a large source-file read into a **signature
outline**: imports plus class/function/method signatures, bodies elided, each
annotated with the exact line range. The agent expands any body with a single
`Read <file> offset=<start> limit=<n>` (or `sed -n 'S,Ep' <file>`). The file is
never modified — it *is* the byte-exact backup.

Zero dependencies: symbols are found with `grep`/`awk` (no tree-sitter or ctags
required). Covers Python, JS/TS, Go, Rust, Java/Kotlin/Scala, Ruby, C/C++, PHP,
and Swift. Guards against regression: only files over `QUIET_OUTLINE_MIN_BYTES`
(default 30000) are outlined, only known source extensions, and a file with
fewer than `QUIET_OUTLINE_MIN_SYMBOLS` (default 3) symbols falls back to the
normal head/tail preview.

### Large tool results (MCP, WebFetch, WebSearch — not just MCP)

Tool *results* are the third big context sink — MCP web-search dumps, DB rows,
API payloads, `WebFetch`/`WebSearch` output — they land in context whole and get
re-sent every later turn. On **Claude Code**, a `PostToolUse` hook (matcher
`mcp__.*|WebFetch|WebSearch`) fires after a tool returns: if the result is large
it **spills the byte-exact payload to a file** and replaces what the model sees
with a compact summary —

- **JSON result** → collapsed preview + the `quiet-query` drill-in footer;
- **plain-text result** → head + tail + `"…spilled to <file>"` with a `sed`/`grep`
  drill-in.

It mirrors the result's shape (a string result is replaced with a string, an
MCP `content[]` result with `content[]`) and **passes through any shape it
doesn't recognize** — safe no-op, never breakage. Small results and non-text
content also pass through. Lossless: only the *preview* shrinks. Tune with
`QUIET_RESULT_MIN_BYTES` (default 25000).

**Across agents** (same shared core, different hook fields):

| Agent | Adapter | Hook → replace field |
|---|---|---|
| **Claude Code** | `adapters/claude-code-result.sh` | `PostToolUse` → `updatedToolOutput` (shape-mirrored) |
| **GitHub Copilot CLI** | `adapters/copilot-result.sh` | `postToolUse` → `modifiedResult.textResultForLlm` |
| **Gemini CLI** | `adapters/gemini-result.sh` | `AfterTool` → `decision:"deny"`+`reason` ⚠️ |
| Codex | — | can't rewrite results yet |

> ⚠️ Gemini has no success-preserving replace field — the only way to substitute
> text is `decision:"deny"`+`reason`, which marks the call as *denied* (the model
> may read it as a failed tool call). Use with that in mind. **Codex** can't
> rewrite tool results via a hook — for Codex and any other MCP client, use the
> **MCP proxy** below. The Claude Code adapter is contract-tested; the
> Copilot/Gemini result adapters follow documented schemas but aren't run live.

#### Universal MCP proxy (any client, incl. Codex)

For clients without a result-rewrite hook, `proxy/quiet-mcp-proxy.mjs` sits
between the client and a real MCP server: it forwards every MCP message verbatim
except large `tools/call` results, which it spills + collapses (same summarizer).
Point your client's server config at the proxy instead of the server directly:

```jsonc
// before:  "command": "npx", "args": ["-y", "some-mcp-server"]
// after:
"command": "node",
"args": ["/abs/path/to/quiet-bash/proxy/quiet-mcp-proxy.mjs", "npx", "-y", "some-mcp-server"]
```

Works for **any** MCP client (Claude Code, Codex, Cursor, …) since it operates at
the transport layer. Lossless; tune with `QUIET_RESULT_MIN_BYTES`. Requires
`node` (+ `bash`/`jq` for the summarizer). Buffers each result to measure size,
so it's for request/response servers, not incremental streaming.

## Supported agents

The detection + rewrite logic lives in one agent-agnostic core
(`core/quiet-core.sh`); a thin adapter per agent translates that agent's hook
I/O. Command rewriting requires the agent to support *modifying* a command
before it runs — not every agent does.

Two integration styles. **Hooks** (cleanest — the agent rewrites the command
itself) for agents that support it, and a **universal shell wrapper** that works
literally everywhere else, including your own terminal.

| Agent | Adapter | Mechanism |
|---|---|---|
| **Claude Code** | `adapters/claude-code.sh` | `PreToolUse` → `hookSpecificOutput.updatedInput.command` |
| **OpenAI Codex CLI** | `adapters/codex.sh` | `PreToolUse` → `permissionDecision: allow` + `updatedInput.command` |
| **Gemini CLI** | `adapters/gemini.sh` | `BeforeTool` (matcher `run_shell_command`) → `hookSpecificOutput.tool_input` |
| **GitHub Copilot CLI** | `adapters/copilot.sh` | `preToolUse` → `permissionDecision: allow` + `modifiedArgs` |
| **Cursor / Aider / Windsurf / Cline / OpenCode / any** | `adapters/shell-wrapper.sh` | shell functions sourced in `~/.bashrc`/`~/.zshrc` — no agent hook needed |
| **Your own terminal** | `adapters/shell-wrapper.sh` | same — quiets your interactive shell too |

So: agents with a command-rewriting hook use a hook; everything else (Cursor and
Aider have no command-rewrite hook) uses the shell wrapper. Either way, you're
covered.

> **Verification status.** The Claude Code adapter, the shell wrapper, and the
> PATH shims are tested end-to-end. The Codex, Gemini, and Copilot adapters are
> **contract-verified** — their input parsing and output shape are tested against
> each CLI's documented hook schema (this caught a real bug: Copilot sends
> `toolArgs` as a JSON-encoded *string*, now handled). They have **not** yet been
> run against a live authenticated CLI. Known caveat: Codex's `updatedInput`
> rewrite needs a recent Codex version (older ones reject it). Issues/PRs from
> live users welcome.

## Install

### Claude Code

This repo doubles as a single-plugin marketplace:

```
/plugin marketplace add yoeld-wix/quiet-bash
/plugin install quiet-bash@quiet-bash
```

Restart Claude Code so the hook registers. To install manually instead, add a
`PreToolUse` hook to `~/.claude/settings.json` pointing at the adapter:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "/abs/path/to/quiet-bash/adapters/claude-code.sh", "timeout": 10 }
      ] }
    ]
  }
}
```

### OpenAI Codex CLI

```
codex plugin marketplace add yoeld-wix/quiet-bash
```

Then register `adapters/codex.sh` as a `PreToolUse` hook in `~/.codex/hooks.json`
(or run `./install.sh codex` to print the config) and approve it via `/hooks`.

### Gemini CLI

```
gemini extensions install https://github.com/yoeld-wix/quiet-bash
```

Then add a `BeforeTool` hook in `settings.json` with
`matcher: "run_shell_command"` running `adapters/gemini.sh`
(or `./install.sh gemini`).

### GitHub Copilot CLI

```
copilot plugin marketplace add yoeld-wix/quiet-bash
```

Then add a `preToolUse` hook in `.github/hooks/quiet-bash.json` running
`adapters/copilot.sh` (or `./install.sh copilot`).

### Cursor, Aider, Windsurf, Cline, or any shell (universal)

These agents have no command-rewriting hook, so quiet-bash intercepts at the
shell level. Two ways:

**PATH shims (recommended for agents).** Agents usually run commands in
*non-interactive* shells that never source your rc, so generate real shim
executables and put them first on `PATH`:

```bash
./adapters/install-shims.sh            # creates ~/.quiet-bash/shims
export PATH="$HOME/.quiet-bash/shims:$PATH"   # add to rc AND the agent's env
```

This works under every shell type because it's `PATH`, not rc — the same
mechanism `asdf`/`pyenv` use. (Explicit paths like `./gradlew` bypass it by
design; the hook adapters catch those.)

**rc functions (simplest for your own terminal).** For interactive shells:

```bash
echo 'source /abs/path/to/quiet-bash/adapters/shell-wrapper.sh' >> ~/.zshrc
# or ~/.bashrc
```

Both define wrappers for the verbose tools (`yarn`, `npm`, `pytest`, `cargo`,
`gradle`, `jest`, …) that redirect output to a log and print a summary;
`--version`/`--help` and non-build subcommands pass through. `git diff/show/log`
is left alone here (you usually want it in an interactive shell).

## Configuration

Override via environment variables (defaults shown):

| Variable | Default | Meaning |
|---|---|---|
| `QUIET_LOG_DIR` | `$TMPDIR` or `/tmp` | where redirect logs are written |
| `QUIET_INLINE_LINE_LIMIT` | `60` | git output up to this many lines is shown inline |
| `QUIET_FAIL_TAIL_LINES` | `40` | lines of a failed command's log to surface |
| `QUIET_LOG_RETENTION_MINUTES` | `1440` | prune redirect logs older than this on each run |

- `QUIET_OUTLINE_MIN_BYTES` (default 30000) — outline source files larger than this.
- `QUIET_OUTLINE_MIN_SYMBOLS` (default 3) — below this many symbols, skip outlining.

To cover more commands, extend the `always`/`managed` patterns in
`core/quiet-core.sh`.

## Requirements

- A supported agent (see table above), or any shell for the universal wrapper
- `jq` and `bash` on `PATH`

## How it works

Each adapter reads its agent's pre-tool event JSON, extracts the shell command,
and calls `quiet_rewrite` from the core. For a known-verbose command the core
returns a rewritten command that redirects output to `mktemp` and prints only a
summary; the adapter wraps that in whatever rewrite field its agent expects.
Non-matching commands return nothing, so they run unchanged. Each invocation
also prunes redirect logs older than `QUIET_LOG_RETENTION_MINUTES`.

## Benchmark

The savings numbers above come from a 10-subagent benchmark over a mix of real
and modeled commands:

- **5 real** commands were executed on a production monorepo and their combined
  stdout+stderr measured (`git diff HEAD~25 HEAD`, `git log --stat -150`,
  `git log -p -12`, `git log --oneline -1200`, a repo-wide `find`).
- **5 modeled** commands used representative logs for build/test/install flows
  (`yarn build`, `jest`, `yarn install`, `docker build`, `eslint + tsc`).

For each, raw output tokens were estimated as `bytes ÷ 4` and compared against
the fixed ~25-token summary quiet-bash leaves behind. The session projection
assumes ~40% of turns run a verbose command, each resident for ~half the
remaining session — change those and the absolute numbers move, but a verbose
command going from tens of thousands of tokens to ~25 is exact.

> Honesty note: the **99.9%** figure is the reduction in *command-output*
> tokens, which are typically the largest single slice of an agentic session's
> context — not a claim that your total bill drops 99.9%. Your overall saving
> depends on how much of your session is verbose command output.

## FAQ

**Does it hide errors?** No. On a non-zero exit it prints the last
`QUIET_FAIL_TAIL_LINES` (40) lines inline plus the log path, so the agent sees
what failed and can grep the rest.

**Where does the full output go?** A temp file (`$TMPDIR/claude-cmd-XXXXXX`). The
agent can `grep`/`tail` it anytime; logs older than 24h are pruned automatically.

**Will it break commands whose output I actually need?** It only wraps known-
verbose build/test/install/CI commands and *large* `git diff/show/log`. Small git
output, `ls`, `cat`, `grep`, `gh`, etc. pass through untouched.

**What's the overhead?** A short command is never wrapped (wrapping costs an
extra round-trip), so there's effectively none where it wouldn't pay off.

**Does it work outside an agent?** Yes — the shell wrapper / PATH shims quiet your
own interactive terminal too.

**Are all the adapters tested?** The Claude Code adapter, the shell wrapper, and
the PATH shims are covered by CI. The Codex/Gemini/Copilot adapters follow each
tool's documented hook format but aren't yet verified on a live install — issues/
PRs welcome.

## License

MIT
