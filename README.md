<p align="center">
  <img src="assets/logo.svg" alt="quiet-bash" width="440">
</p>

<p align="center">
  <em>Stop paying to re-read build logs your agent already skimmed.</em>
</p>

<p align="center">
  <a href="#supported-agents">Works with Claude Code · Codex · Gemini · Copilot · Cursor · Aider · any shell</a> ·
  <a href="LICENSE">MIT</a>
</p>

---

A hook (and universal shell wrapper) that keeps noisy command output out of an
AI coding agent's context window.

When the agent runs a known-verbose command — a test run, a build, a buildkite
invocation, a `docker build`, a `bazel build/test`, or a big `git diff` — the
full output is redirected to a temp log file and the agent only sees a short
summary. On failure it still gets the tail of the log (and a pointer to grep
the rest), so nothing important is lost.

Short, quick commands are passed through untouched: wrapping them would cost
more in extra round-trips than it would save.

## How much it saves

> **Across 10 real commands on a production monorepo, raw output totaled
> `536,957` tokens. quiet-bash replaced them with `~250` tokens of summaries —
> a `99.9%` cut on the command output that reaches the model.**

<p align="center">
  <img src="assets/savings.svg" alt="Token savings per command" width="820">
</p>

| | Without quiet-bash | With quiet-bash | Reduction |
|---|--:|--:|--:|
| Average verbose command | ~53,700 tok | ~25 tok | **99.95%** |
| All 10 commands (this benchmark) | 536,957 tok | 250 tok | **99.9%** |

<sub>10-subagent benchmark on a real monorepo — 5 commands run live, 5 modeled
from representative logs. Token estimate ≈ bytes ÷ 4. Methodology in
[Benchmark](#benchmark).</sub>

### Bottom line for an average dev

**≈ 30 % lower token cost on a typical session** — ranging from ~15–20 % for
read/edit-heavy work to **50 %+** for build- and test-heavy workflows. The rule
of thumb:

> total saving ≈ (share of your context that is command output) × 99 %

The **99.9 %** cut on command output is measured. The session-level percentage
is a model — it depends on how log-heavy your work is, and prompt caching /
context compaction move it around — so treat ~30 % as a representative midpoint,
not a guarantee.

| Your workflow | Command output ≈ | Total token cost saved |
|---|--:|--:|
| Light (mostly reading/editing) | ~15–20 % of context | **~15–20 %** |
| Typical (regular test/build loops) | ~30–40 % | **~30 %** |
| Heavy (TDD, CI-debugging, full builds) | ~50–60 % | **~50 %+** |

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
| everything else (`ls`, `cat`, `grep`, `git status`, `gh …`, …) | Passed through unchanged. |

Already-bounded commands (those with `--stat`, `--oneline`, a pipe to
`head`/`grep`/…, or a `>` redirect) are left alone, and the hook never
double-wraps its own output or a follow-up read of a log file.

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

> The Claude Code adapter and the shell wrapper are tested. The Codex, Gemini,
> and Copilot adapters are written to each tool's **documented** hook format but
> have not been verified against a live install — confirm field names against
> your version, and please open an issue/PR if anything needs adjusting.

## Install

### Claude Code

This repo doubles as a single-plugin marketplace:

```
/plugin marketplace add yoeld-wix/claude-quiet-bash
/plugin install claude-quiet-bash@claude-quiet-bash
```

Restart Claude Code so the hook registers. To install manually instead, add a
`PreToolUse` hook to `~/.claude/settings.json` pointing at the adapter:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "/abs/path/to/claude-quiet-bash/adapters/claude-code.sh", "timeout": 10 }
      ] }
    ]
  }
}
```

### OpenAI Codex CLI

Register `adapters/codex.sh` as a `PreToolUse` hook in `~/.codex/hooks.json`
(see [Codex hooks docs](https://developers.openai.com/codex/hooks)), then
approve it via `/hooks`.

### Gemini CLI

Add a `BeforeTool` hook in `settings.json` with `matcher: "run_shell_command"`
running `adapters/gemini.sh`
(see [Gemini CLI hooks reference](https://geminicli.com/docs/hooks/reference/)).

### GitHub Copilot CLI

Add a `preToolUse` hook in `.github/hooks/quiet-bash.json` running
`adapters/copilot.sh`
(see [Copilot hooks configuration](https://docs.github.com/en/copilot/reference/hooks-configuration)).

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
echo 'source /abs/path/to/claude-quiet-bash/adapters/shell-wrapper.sh' >> ~/.zshrc
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

## License

MIT
