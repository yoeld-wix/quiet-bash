# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versioning is [SemVer](https://semver.org/).

## [1.8.0] — 2026-06-21

### Added
- **Large-JSON read optimization** (`core/quiet-json.sh`): a `cat`/`bat`/`head`/
  `jq .` of a `*.json` file over `QUIET_JSON_MIN_BYTES` (25 KB) is rewritten into
  a collapsed preview — repeated object/array shapes fold to `"N more of M,
  same shape"`, long strings truncate, and a `jq`/`grep` drill-in footer points
  at the (untouched) file. ~299k → ~660 tokens on a real `package-lock.json`.
- The collapsed-preview format was selected over gron-flat and schema-only by an
  A/B/C benchmark (fewest tokens, equal accuracy, zero hallucinated values).
- Pass-through for small files, `jq`/`yq` projections, and piped/redirected
  commands. New JSON tests in the suite.

### Notes
- YAML read optimization is planned (will use `yq`).

## [1.7.0] — 2026-06-21

### Changed
- **Renamed `claude-quiet-bash` → `quiet-bash`** across the repo, plugin name,
  marketplace manifests, and install commands (repo now at
  `github.com/yoeld-wix/quiet-bash`).
- **New logo + icon** (`assets/logo.svg`, `assets/icon.svg`): noisy log lines
  collapsing through a bash-prompt chevron into one quiet line — survives the
  16px favicon test, legible on light and dark.

## [1.6.0] — 2026-06-21

### Added
- **Marketplace / extension distribution** for more agents (verified formats):
  `.github/plugin/marketplace.json` (Copilot CLI — also reads the existing
  `.claude-plugin/marketplace.json`), root `gemini-extension.json` (Gemini CLI),
  and `.codex-plugin/plugin.json` (Codex CLI). One-liner installs in the README.
- CI now validates the new manifests.

### Notes
- Codex *marketplace-catalog* schema and OpenCode (npm-only) are intentionally
  not auto-authored — see README. Hook activation per agent still uses each
  agent's documented hook config.

## [1.5.0] — 2026-06-21

### Added
- **Test suite** (`tests/run.sh`) covering core decisions, all four hook adapter
  output shapes, and PATH-shim wrap/passthrough behavior.
- **CI** (GitHub Actions): ShellCheck + JSON validation + the test suite on every
  push and PR.
- **One-command installer** (`install.sh`) with `shims`, `shell`, `claude`,
  `codex`, `gemini`, and `copilot` targets.
- **FAQ** and a before/after **examples** transcript in the docs.
- Badges and a per-workflow cost-saving chart in the README.

## [1.4.0] — 2026-06-21

### Added
- **PATH shims** (`adapters/quiet-shim.sh`, `adapters/install-shims.sh`) so
  quiet-bash works under non-interactive agent shells (Cursor/Aider/…) that never
  source rc.
- **Measured savings + chart**: 10-subagent benchmark (`assets/savings.svg`) —
  536,957 tokens of command output → ~250 tokens of summaries.

### Fixed
- macOS `/var`→`/private/var` self-detection that made shims `exec`-loop.

## [1.3.0] — 2026-06-21

### Added
- **Universal shell wrapper** (`adapters/shell-wrapper.sh`) + `quiet_run` runtime
  executor in the core.
- Project **logo** (`assets/logo.svg`).

## [1.2.0] — 2026-06-21

### Added
- Adapters for **Codex CLI, Gemini CLI, and GitHub Copilot CLI** (documented hook
  formats; only the Claude Code adapter is live-tested).

## [1.1.0] — 2026-06-21

### Changed
- Broadened verbose-command coverage across JS/Python/JVM/Go/Rust/Ruby/C and
  containers; recognize path-prefixed tools like `./gradlew`.

## [1.0.0] — 2026-06-21

### Added
- Initial release: Claude Code `PreToolUse` hook that redirects verbose command
  output to a temp log and surfaces only a summary, with a smart `git`
  diff/show/log path and automatic log pruning.
