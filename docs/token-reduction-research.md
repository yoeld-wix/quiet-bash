# Token-Reduction Research — next directions for quiet-bash

Synthesis of three parallel research sweeps (academic literature, open-source
prior art, official Claude Code / Codex / Anthropic API docs), filtered through
quiet-bash's hard constraints: **mechanical** (no extra LLM call),
**lossless-or-byte-exact-recoverable**, operating at the **tool-output boundary**
(hook / shell-wrapper / MCP proxy), and **no regression in result quality**.

Already shipped (not repeated below): verbose command output → summary; large
JSON/YAML reads → collapsed preview; large tool/MCP/WebFetch results →
spill+collapse; `quiet-query` over spilled files.

---

## Headline finding: the prompt cache governs whether transcript edits help or hurt

Anthropic prompt caching reuses computation only for the **longest exact-match
prefix**; any change to content at or before a `cache_control` breakpoint
re-bills the whole suffix at ~10× (cache read ≈ 0.1× input; miss = 1.0×).

Implication for quiet-bash:

- **Rewriting the just-emitted tool result at the tail (current behavior) is
  cache-safe** — it lands after the breakpoint, nothing downstream to
  invalidate. This is quiet-bash's natural regime.
- **Retroactively editing *old* tool results (cross-turn masking) busts the
  cache** for everything after the edit. It is only worth it when batched behind
  a "minimum tokens cleared" threshold that beats the one-time re-cache cost —
  exactly how Anthropic's own context-editing (`clear_tool_uses_20250919`,
  knobs `trigger`/`keep`/`clear_at_least`) gates it.
- Rules: never touch the `tools`/`system` layers or reorder earlier messages;
  keep rewrites **deterministic** (sorted keys, stable formatting) so re-runs
  don't cause spurious prefix drift; exempt auto-cached server-tool results.

Measured stakes: stable-prefix vs perturbed → 85.2% vs 0% cache-hit, 71.3% cost
reduction in one study. So a cache-safety audit of the existing PostToolUse path
de-risks everything below.

Sources: https://platform.claude.com/docs/en/build-with-claude/prompt-caching ·
https://code.claude.com/docs/en/prompt-caching ·
https://platform.claude.com/docs/en/build-with-claude/context-editing ·
https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-use-with-prompt-caching

---

## Tier 1 — biggest unaddressed sinks

### 1. Cross-turn observation masking + duplicate-read dedup  ⭐ top fit
Once a tool result / file read is older than the last M turns, or is superseded
by a newer read of the same path, replace its in-transcript body with a stub
(`[masked — full payload at <spill>, drill in with <cmd>]`). Keep the agent's
action/reasoning trace intact; only stub the observation body.

- **Why it fits quiet-bash uniquely:** everyone else's masking is *lossy*; yours
  is **near-lossless** because the full bytes already live on a spill file.
- **Evidence (strong, convergent):**
  - OpenHands `ObservationMaskingCondenser` (default M=5) + arXiv 2508.21433
    "The Complexity Trap": on SWE-bench Verified (500), masking **matched or beat
    LLM summarization** (Qwen3-Coder 54.8% vs 53.8%; Gemini 2.5 Flash +5pts) at
    **50.9–57.1% cost reduction**, and avoided the "trajectory elongation" that
    summarization causes. https://arxiv.org/html/2508.21433v1
  - Cline `ContextManager.ts` duplicate-file-read dedup: keep newest read,
    stub older identical-path reads via a reversible timestamp-keyed overlay.
  - "Merlin" byte-exact dedup: aggregate quality delta **+0.0pp / −0.5pp** across
    Gemini/Claude/GPT-5.1/Llama, ~1.1µs in-process. https://arxiv.org/html/2605.09990
- **Cache interaction:** retroactive → **gate behind a min-tokens-cleared
  threshold** (see headline finding).
- **Regression risk:** LOW for quiet-bash (spill keeps bytes; M tunable).

### 2. Source-code outlining — "signatures not bodies"  ⭐
Large source-file reads → tree-sitter signature skeleton (`def foo(x): …  # body
lines 12–48`), bodies elided with a drill-in to read the exact range.

- **Prior art:** Aider repo map (tree-sitter `tags.scm` + PageRank into a ~1k
  token budget, https://aider.chat/docs/repomap.html), Repomix `--compress`
  (~70% reduction, https://repomix.com/guide/code-compress).
- **Why mechanical + reversible:** tree-sitter `tags` gives full-node span and
  name span separately — enough to slice signature from body; line anchors make
  it losslessly re-fetchable. Syntax-error tolerant, no build/LSP needed; ctags
  fallback for languages lacking a grammar.
- **Regression risk:** LOW (only bodies elided, re-fetchable by range).

---

## Tier 2 — upgrade what we already collapse

### 3. Mechanical log-collapse upgrades
Before summarizing/spilling command output: (a) **strip ANSI** escapes and
collapse `\r`-overwritten progress/spinner lines to final state (lossless);
(b) **Drain-style** template-cluster near-identical lines → `<line> (×1000)`;
(c) surface **error-region + tail** rather than head-only.

- **Prior art:** RTK "Rust Token Killer" wraps 100+ commands, ~89% mechanical
  noise removal, <10ms, no API key (https://github.com/rtk-ai/rtk); Drain3
  (https://github.com/logpai/Drain3); LogDx-CI benchmark (35 real GH-Actions
  failures): **hybrid grep+tail routers dominate the cost-quality Pareto front**,
  4.5× fewer tokens than grep at equal quality, LLM summarizers not worth it
  (https://arxiv.org/abs/2605.28876).
- **Regression risk:** LOW for ANSI/`\r`; MEDIUM for Drain merge (tune similarity;
  full spill mitigates).

### 4. Compact search-output ladder (grep / rg / find / ls -R)
New intercept class (passed through today). Large search output → collapse to a
file-list + per-file counts with a drill-in to re-run with fuller flags. Escalating
ladder: `-l` → `-c` → `-o` → `-C N` → full lines → Read range. `-M`/`--max-columns`
caps giant minified lines.
- Refs: ripgrep flags; Cline ripgrep cap (MAX_RESULTS=300, 0.25MB); Claude Code
  Grep `head_limit`.
- **Regression risk:** LOW–MEDIUM (counts lose match text; recoverable by re-run;
  keep above a threshold).

### 5. JSON minify always + templated record tables (never headerless CSV)
- **Minify** structural whitespace first — fully lossless, **10–30%**; recovers
  much of what fancier re-encoders claim.
- **Template** uniform record arrays to header+rows (TOON / markdown table):
  **30–60%** on large uniform arrays, read-accuracy holds **when headers kept**.
- **Hard guardrail:** do NOT collapse to headerless CSV/pipe-delimited — an
  11-format study (GPT-4.1-nano, 1k records) found the most token-efficient
  formats were the **least accurately read** (CSV 44.3%, pipe 41.1% vs
  Markdown-KV 60.7%, JSON 52.3%); effect worst on small models, negligible on
  frontier models. Tune aggressiveness by model tier.
- Refs: https://www.improvingagents.com/blog/best-input-data-format-for-llms/ ·
  https://github.com/toon-format/toon
- **Regression risk:** LOW (minify); LOW–MEDIUM (templating; verify shared keys,
  null-fill ragged rows or fall back to JSON).

---

## Tier 3 — proxy-side (MCP)

### 6. MCP tool-schema slimming / deferred loading
Tool *definitions* are re-sent every turn (~55k tokens for a 5-server setup).
Front MCP servers with 2–3 generic wrappers (`list_tools` / `get_tool_schema` /
`invoke_tool`) and lazy-load each full schema only on use.
- **Prior art:** Anthropic Tool Search Tool `defer_loading` (native, cache-safe by
  leaving the prefix untouched); Atlassian **mcp-compressor** (94-tool GitHub
  server 17.6k → ~500 tokens, https://github.com/atlassian-labs/mcp-compressor);
  Speakeasy Gram (96% reduction, 100% task success); kira-autonoma
  **mcp-context-proxy** (lossless ~6.5×).
- **Cache caveat:** a proxy rewriting the tool list can bust the cache — prefer
  the native deferred-loading shape; keep stubs stable.
- **Regression risk:** LOW (full schema fetched on demand).

### 7. MCP `resource_link` + tabular re-encode for spilled results
Return a spec-compliant `resource_link` URI to the spill file instead of a bare
text one-liner; re-encode tabular JSON results as CSV/columnar before spilling
(~29%, lossless). Refines the existing MCP-response spill. **Risk: LOW.**

---

## Avoid (lossy and/or require an LLM call — the line not to cross)
- **LLMLingua / LLMLingua-2** — perplexity/classifier token-dropping; out-of-domain
  retention drops to ~75% at 5×; drops syntactically load-bearing tokens. HIGH
  risk for code/logs. https://arxiv.org/html/2403.12968v2
- **Selective-Context** — self-information pruning; "negligible BERTScore loss" is
  a fuzzy-similarity claim, unsafe for code/structured data. HIGH risk.
- **ACON / `/compact` / anchored summarization** — LLM compressors; Factory's eval
  scored every method poorly on "artifact trail" (silently loses file/artifact
  details); OpenAI `/compact` hit 99.3% reduction but lowest accuracy. MEDIUM–HIGH.

All three independently confirm quiet-bash's founding decision (cf. the prior
context-compression eval): mechanical collapsing beats LLM summarization on cost
*and* quality for the agent observation path.

---

## Recommended sequencing (4 independent features, each its own spec → plan → build)
1. **Cross-turn masking + dedup (#1)** + **prompt-cache safety audit** — highest
   leverage, best-evidenced, near-lossless here; the cache audit de-risks it.
2. **Source-code outlining (#2)** — novel, high-value, reversible.
3. **Log-collapse upgrades (#3)** — cheap, compounds across all passthrough.
4. **MCP schema slimming (#6)** — proxy-side, attacks per-turn schema bloat.

(Tier-2 #4/#5 and Tier-3 #7 are smaller follow-ons that can fold into the above.)
