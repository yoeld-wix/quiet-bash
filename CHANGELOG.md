# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versioning is [SemVer](https://semver.org/).

## [1.14.0] — 2026-06-22

### Added
- **Universal MCP proxy** (`proxy/quiet-mcp-proxy.mjs`, Node): a transport-level
  proxy that wraps a real MCP server, forwards every message verbatim except
  large `tools/call` results, which it spills + collapses via the shared
  summarizer (`core/quiet-result.sh`). Works for **any** MCP client including
  **Codex** and others without a result-rewrite hook. Lossless; tune with
  `QUIET_RESULT_MIN_BYTES`. New `core/quiet-result.sh` CLI wrapper; node-gated
  proxy tests + `node --check` in the suite.

## [1.13.0] — 2026-06-22

### Added
- **Tool-result optimization for all hook-capable agents.** New
  `adapters/copilot-result.sh` (`postToolUse` → `modifiedResult.textResultForLlm`)
  and `adapters/gemini-result.sh` (`AfterTool` → `decision:"deny"`+`reason`;
  Gemini has no success-preserving replace field — flagged). Extracted the spill
  + collapse logic into a shared core function `quiet_result_summarize` reused by
  all three result adapters. Codex can't rewrite results yet.

## [1.12.0] — 2026-06-22

### Changed
- **Tool-result optimization now covers non-MCP tools too** (WebFetch, WebSearch
  — not just MCP). Renamed `claude-code-mcp.sh` → `claude-code-result.sh`;
  PostToolUse matcher broadened to `mcp__.*|WebFetch|WebSearch`. The adapter
  mirrors the result's shape (string→string, MCP `content[]`→`content[]`) and
  safely passes through any shape it doesn't recognize. Knob renamed
  `QUIET_MCP_MIN_BYTES` → `QUIET_RESULT_MIN_BYTES` (old name still honored).

## [1.11.0] — 2026-06-22

### Added
- **`core/quiet-query.sh` — smart query & aggregation over a spilled file.**
  jq-backed ops: `keys`, `count`, `get`, `sample`, `pluck`, `select` (filter),
  `group` (count-by-field), `stats` (count/min/max/sum/avg), `search`. Works on
  JSON and YAML via the shared converter. Each op returns a small focused answer
  so a huge spilled result is interrogated cheaply instead of re-read.
- Collapsed-preview footers (file reads + MCP JSON results) now advertise
  `quiet-query` ops instead of only raw jq.

### Changed
- Hoisted the YAML→JSON converter into the core (`quiet_to_json`); `quiet-json.sh`
  now sources the core and reuses it.

## [1.10.0] — 2026-06-22

### Added
- **Large MCP response optimization** (Claude Code `PostToolUse` hook, matcher
  `mcp__.*`): when an MCP tool result exceeds `QUIET_MCP_MIN_BYTES` (25 KB), the
  full byte-exact payload is spilled to a file and the model sees a compact
  summary instead — JSON results reuse the collapsed-preview + `jq` footer; text
  results get head/tail + a `sed`/`grep` drill-in. Replaces the result via
  `hookSpecificOutput.updatedToolOutput`. Small results and non-text content pass
  through. New adapter `adapters/claude-code-mcp.sh`; MCP tests added.
- Lossless by design (only the preview shrinks). Gemini/Copilot adapters and a
  universal MCP proxy are planned; Codex can't rewrite results yet.

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
