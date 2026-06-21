# claude-quiet-bash

A [Claude Code](https://claude.com/claude-code) plugin that keeps noisy Bash
output out of the model's context window.

When Claude runs a known-verbose command — a test run, a build, a buildkite
invocation, a `docker build`, a `bazel build/test`, or a big `git diff` — the
full output is redirected to a temp log file and Claude only sees a short
summary. On failure it still gets the tail of the log (and a pointer to grep
the rest), so nothing important is lost.

Short, quick commands are passed through untouched: wrapping them would cost
more in extra round-trips than it would save.

## Why

Build and test logs are the single biggest source of wasted tokens in an agent
session — hundreds of lines of progress output that Claude reads once and never
needs again. This hook turns a 600-line `yarn test` dump into a one-line
"exit 0 — 612 lines hidden in /tmp/claude-cmd-XXXXXX", while keeping failures
fully diagnosable.

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

## Install

This repo doubles as a single-plugin marketplace.

```
/plugin marketplace add yoeld-wix/claude-quiet-bash
/plugin install claude-quiet-bash@claude-quiet-bash
```

Then restart Claude Code (or start a new session) so the hook registers.

### Manual install

Copy `hooks/quiet-bash.sh` somewhere on disk, make it executable, and add a
`PreToolUse` hook to your `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "/abs/path/to/quiet-bash.sh", "timeout": 10 }
        ]
      }
    ]
  }
}
```

## Configuration

Tunables live at the top of `hooks/quiet-bash.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `LOG_DIR` | `$TMPDIR` or `/tmp` | where redirect logs are written |
| `INLINE_LINE_LIMIT` | `60` | git output up to this many lines is shown inline |
| `FAIL_TAIL_LINES` | `40` | lines of a failed command's log to surface |
| `LOG_RETENTION_MINUTES` | `1440` | prune redirect logs older than this on each run |

To cover more commands, extend the `VERBOSE_RE` pattern.

## Requirements

- Claude Code with plugin/hook support
- `jq` and `bash` on `PATH`

## How it works

The hook is a `PreToolUse(Bash)` command. It reads the event JSON on stdin and,
for a matching command, emits an `updatedInput` object that rewrites the command
to redirect its output to `mktemp` and print only a summary. Non-matching
commands produce no output, so they run unchanged. Each run also prunes redirect
logs older than `LOG_RETENTION_MINUTES`.

## License

MIT
