# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versioning is [SemVer](https://semver.org/).

## [1.9.1] — 2026-06-22

### Fixed
- **Copilot adapter**: parse the command from `toolArgs` (a JSON-encoded
  *string* that must be double-decoded) plus the snake_case `tool_input` alias —
  the previous code read non-existent fields and silently no-op'd. Found by
  contract-verifying adapter input parsing against each CLI's documented hook
  schema; tests now use the real per-CLI payloads.

### Notes
- Codex/Gemini adapters confirmed against their documented schemas
  (`.tool_input.command`). Codex's `updatedInput` rewrite requires a recent
  Codex version. Adapters are contract-verified but not yet run live.

## [1.9.0] — 2026-06-21

### Added
- **YAML read optimization**: large `*.yaml`/`*.yml` reads get the same collapsed
  preview as JSON. YAML→JSON conversion uses a fallback ladder — `ruby` →
  `python3`+PyYAML → `yq` — so it works out of the box (Ruby's stdlib ships
  yaml+json; present on macOS and CI) with **no hard dependency**; passes through
  if no converter is available. Multi-doc YAML becomes an array. New YAML tests.

## [1.8.1] — 2026-06-21

### Changed
- Adopted the **sloth mascot logo** (`assets/logo.png`) and the **compact
  benchmark / workflow charts** (`assets/savings-compact.svg`,
  `assets/workflow-context-stacks.svg`) from the merged research PR as the
  canonical brand assets; removed the earlier abstract SVG logo/icon and chart
  variants. Fixed a viewBox clip in the workflow chart.

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
