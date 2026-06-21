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

## Why this reduces cost

Build and test logs are the single biggest source of wasted tokens in an agent
session — hundreds of lines of progress output that Claude reads once and never
needs again.

The key thing to understand is **how LLM billing works in a multi-turn agent
loop**: the model is stateless, so on *every* turn the entire conversation so
far — including all previous command outputs — is re-sent as input tokens. A log
isn't paid for once when it's produced; it's paid for again on every subsequent
turn it stays in the context window.

So a single 600-line `yarn test` dump near the start of a 40-step task isn't
~600 lines of cost — it's roughly **600 lines × the number of turns that
follow**, because it rides along in the input of each one. Multiply that across
every build, test, and install in a session and log noise becomes the dominant
input-token cost.

This hook turns that 600-line dump into a one-line
`[ok: exit 0 — 612 lines hidden in /tmp/claude-cmd-XXXXXX]`. The full output
still exists on disk (Claude can `grep`/`tail` it if it genuinely needs a
detail), but it never enters the context window, so you stop paying to re-send
it turn after turn. Concretely, it:

- **shrinks input tokens on every later turn** — the expensive, repeated cost,
  not just a one-time saving;
- **keeps the prompt-cache prefix stable** — fewer giant, varying tool results
  means more of the context can stay cached and cheap;
- **preserves debuggability** — on failure it still surfaces the last 40 lines
  inline, and small `git diff`/`show`/`log` output is shown as normal, so the
  savings don't cost you the information you actually need.

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

For agents without a command-rewriting hook — and for your own terminal — source
the shell wrapper from your shell rc:

```bash
echo 'source /abs/path/to/claude-quiet-bash/adapters/shell-wrapper.sh' >> ~/.zshrc
# or ~/.bashrc
```

It defines shell functions for the verbose tools (`yarn`, `npm`, `pytest`,
`cargo`, `gradle`, `jest`, …) that redirect output to a log and print a summary.
`--version`/`--help` and non-build subcommands pass through. `git diff/show/log`
is intentionally left alone here (you usually want it in an interactive shell).

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

- A supported agent (see table above) with hooks enabled
- `jq` and `bash` on `PATH`

## How it works

Each adapter reads its agent's pre-tool event JSON, extracts the shell command,
and calls `quiet_rewrite` from the core. For a known-verbose command the core
returns a rewritten command that redirects output to `mktemp` and prints only a
summary; the adapter wraps that in whatever rewrite field its agent expects.
Non-matching commands return nothing, so they run unchanged. Each invocation
also prunes redirect logs older than `QUIET_LOG_RETENTION_MINUTES`.

## License

MIT
