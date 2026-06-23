# Source-File Outlining — Design Spec

**Status:** Approved design, pending implementation plan
**Date:** 2026-06-23
**Feature:** #2 of the token-reduction roadmap (see `docs/token-reduction-research.md`)

## Problem

quiet-bash already collapses large `.json`/`.yaml` reads and large tool results,
but **source-code files are not handled**. A large source read is re-billed at
full size on every subsequent turn, because:

- **Bash path** (`cat foo.py`, `head foo.ts`): `quiet_rewrite` only intercepts
  `.json`/`.yaml` files — source files pass through untouched.
- **Native `Read` tool path** (how Claude Code agents actually read source):
  `quiet_result_summarize` is invoked, but since source isn't JSON it takes the
  text branch (head-20 / tail-10), which is lossy in the middle and not a useful
  view of code.

Source files are therefore the **largest unaddressed token sink** for real
agent sessions: a 1,800-line module re-sent every turn dwarfs the cost of the
already-collapsed JSON/log paths.

## Goal

Replace a large source-file read with a **signature skeleton** — imports plus
class/function/method/type signatures, bodies elided — and give the agent the
**exact line range** to expand any body. Lossless: the source file on disk is
the byte-exact backup; expansion is a single precise `Read <path> offset=X
limit=N` (or `sed -n 'X,Yp' <path>`). No spill file is needed (unlike JSON),
because the original file already is the backup.

Non-goals: semantic/LLM summarization (rejected — see research doc); reformatting
or modifying the source; cross-turn dedup (separate feature #1).

## Core component: `core/quiet-outline.sh <file>`

Mirrors `core/quiet-json.sh`. Input: a file path. Output: an outline + drill-in
footer printed to stdout. Reused by both read paths so there is one source of
truth (same pattern as `quiet-json.sh` / `quiet_to_json`).

### Output format

```
[quiet-bash] UserService.ts — 1,840 lines / 88 KB of TypeScript — outline (bodies elided; expand: Read UserService.ts offset=<start> limit=<n>)
   1  import … (lines 1–22)
  24  export class UserService {
  31    constructor(db: Db) { … }                         body 31–39
  41    async findUser(id: string): Promise<User> { … }   body 41–78
 130  export function helper(x): number { … }             body 130–145
  [42 symbols • full body: Read UserService.ts offset=41 limit=38 • raw: sed -n '41,78p' UserService.ts]
```

- Leading column is the symbol's **start line** in the real file.
- `body A–B` gives the exact range for expansion.
- Indentation reflects nesting depth (methods under a class) where the engine
  can infer it; otherwise flat.
- Imports/`use`/`#include` runs are collapsed to a single `(lines A–B)` entry.
- Footer states symbol count and the two expansion idioms (native `Read` range
  and raw `sed`), so it works for both Claude Code and shell/Codex users.

## Outliner engine: builtin zero-dep regex extractor

A bash/awk signature extractor — **no tree-sitter, no ctags required** (matches
quiet-bash's no-hard-dep ethos; neither is guaranteed installed). ctags/
tree-sitter MAY be used as accelerators later, but are out of scope for v1.

Mechanism:
1. Detect language from the file **extension** (primary, reliable).
2. Apply that language's signature patterns line-by-line to find symbol
   **start lines** (def/function/class/interface/type/struct/enum/trait/impl/
   fn/method-signature/module).
3. Compute each body's **end line** as the line immediately before the next
   symbol at the same-or-shallower indentation/scope (approximate; brace- or
   indentation-aware per language family).
4. Collapse leading import/`use`/`require`/`#include` runs into one entry.
5. Render signature lines with `{ … }` / `: …` body elision + the body range.

Languages covered in v1 (extension → pattern set):
- **JS/TS/JSX/TSX** (`.js .mjs .cjs .ts .tsx .jsx`): `function`, `const x = (…) =>`,
  `class`, `interface`, `type`, `enum`, `export`, object-method shorthand.
- **Python** (`.py`): `def`, `async def`, `class`, decorators attach to the
  following def.
- **Go** (`.go`): `func`, `type … struct`, `type … interface`.
- **Rust** (`.rs`): `fn`, `struct`, `enum`, `trait`, `impl`, `mod`, `pub` forms.
- **Java/Kotlin/Scala** (`.java .kt .kts .scala`): `class`, `interface`, `enum`,
  `object`, method signatures, Scala `def`/`val`.
- **Ruby** (`.rb`): `def`, `class`, `module`.
- **C/C++/headers** (`.c .h .cc .cpp .hpp .cxx`): function signatures, `struct`,
  `class`, `typedef`, `enum`.
- **PHP** (`.php`): `function`, `class`, `interface`, `trait`.
- **Swift** (`.swift`): `func`, `class`, `struct`, `enum`, `protocol`,
  `extension`.

Approximation is acceptable because the body is recoverable byte-exact from the
file — same safety principle as the JSON collapser eliding values.

## Integration (shared core, both paths)

### Bash read path — `quiet_rewrite` (in `core/quiet-core.sh`)

Add a branch parallel to the existing JSON/YAML branch: when the command is a
plain read (`cat/bat/less/more/head/tail`) of a single file whose extension is in
the source allowlist and whose size > `QUIET_OUTLINE_MIN_BYTES`, rewrite the
command to `quiet-outline.sh <file>`. Skip piped/redirected commands and
projections, exactly like the JSON branch.

### Native Read path — `adapters/claude-code-result.sh`

1. Extract `.tool_input.path` (also accept `.tool_input.file_path`) from the
   hook payload — the adapter currently reads only `tool_name`, so add this.
2. If the result is large, the path is set, the file exists, and its extension
   is in the source allowlist and size > `QUIET_OUTLINE_MIN_BYTES`: run
   `quiet-outline.sh` on the **real file** (not the cat-n'd result text, which
   carries line-number prefixes) and return the outline as `updatedToolOutput`
   (mirroring the original result shape, like today).
3. Otherwise fall through to the existing `quiet_result_summarize` behavior.

If `tool_input.path` is absent/unreadable (e.g., content came from stdin), fall
back to current behavior — never guess.

## Regression guards (the "no regression" constraint)

- **Threshold:** fire only when file size > `QUIET_OUTLINE_MIN_BYTES`
  (default **30000**). Small/medium files stay full.
- **Extension allowlist:** only the source extensions above. Never outline prose,
  config, data, lockfiles, or unknown types.
- **Symbol-count floor:** if the engine finds **< 3 symbols** (data-ish file, or
  a language parsed poorly), fall back to the existing head/tail spill — an
  outline of a non-code file is useless and would be a regression.
- **Exact expansion ranges:** every body lists its precise range, so expansion is
  one targeted `Read`, minimizing extra round-trips (the "trajectory
  elongation" risk flagged in the research).
- **Idempotence / no double-wrap:** never outline a file that is itself a
  quiet-bash spill/log; never re-outline already-wrapped output (reuse the
  existing `[quiet-bash]` / `${QUIET_LOG_PREFIX}` guards).

## Cache-safety

Both paths land at the **tail** of the transcript: the Bash command is rewritten
before execution (output is born small); the Read result is rewritten in
PostToolUse (current tool result, after any cache breakpoint). No earlier message
is edited, so the prompt-cache prefix is unchanged. Rendering is **deterministic**
(stable ordering, no timestamps) so re-runs don't cause spurious prefix drift.

## Configuration

- `QUIET_OUTLINE_MIN_BYTES` (default `30000`) — minimum file size to outline.
- `QUIET_OUTLINE_MIN_SYMBOLS` (default `3`) — symbol floor below which we fall
  back to head/tail.
- Honor a global disable consistent with existing knobs (e.g., setting the min
  bytes very high effectively disables it).

## Testing strategy

Unit (in `tests/run.sh`, shellcheck-clean):
1. **Per-language fixtures** — a representative file per language family →
   assert the expected signatures appear and each body range is correct
   (start/end match the real symbol span).
2. **Threshold** — a small source file passes through unchanged; a large one is
   outlined.
3. **Symbol-floor fallback** — a large `.txt`/data-ish file (or a source file
   with no parseable symbols) → head/tail, not an outline.
4. **Range correctness** — for a chosen symbol, `sed -n 'A,Bp' file` returns
   exactly that symbol's body.
5. **Bash-path rewrite** — `quiet_rewrite "cat big.ts"` returns the
   `quiet-outline.sh big.ts` rewrite; `cat big.ts | grep x` (piped) is left
   alone.
6. **Native-Read path** — a PostToolUse payload with `tool_input.path` to a large
   source file → `updatedToolOutput` contains the outline, shape mirrored.
7. **No-deps guarantee** — tests pass with only coreutils/awk (no tree-sitter,
   no universal-ctags), proving the zero-dep baseline.

## Files touched

- `core/quiet-outline.sh` (new) — the outliner CLI + per-language pattern sets.
- `core/quiet-core.sh` (modified) — add the source-read branch to `quiet_rewrite`;
  define `QUIET_OUTLINE_MIN_BYTES` / `QUIET_OUTLINE_MIN_SYMBOLS`.
- `adapters/claude-code-result.sh` (modified) — extract `tool_input.path`; route
  large source reads to the outliner.
- `tests/run.sh` (modified) — the test cases above + language fixtures.
- `README.md`, `CHANGELOG.md` — document the feature; bump version.

## Out of scope (follow-ons)

- ctags/tree-sitter accelerator ladder (optional future accuracy upgrade).
- Outlining inside the universal shell-wrapper for arbitrary shells beyond the
  `cat`/`head` rewrite (the Bash-path rewrite already covers the common case).
- PageRank-style whole-repo ranking (Aider-style) — this feature is per-file.
