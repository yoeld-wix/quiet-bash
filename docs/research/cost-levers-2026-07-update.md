# Cost-lever research — 2026-07-05 update

Follow-up to `docs/token-reduction-research.md`, `docs/maximizing-savings.md`, and
`docs/comparison.md`. Sourced from a 107-agent deep-research sweep (6 search
angles, 24 sources fetched, 110 claims extracted, 25 adversarially verified —
17 confirmed / 8 refuted at 3-vote majority). Most well-known levers (cache
discipline, cross-turn masking, source outlining) are already documented or
shipped; this note only covers what's **new or still unbuilt** relative to the
existing docs, and reconfirms the load-bearing facts with fresher evidence.

Refuted-on-reverification claims are listed at the bottom so a future pass
doesn't resurrect them.

---

## New, concrete candidates

### 1. Extend the MCP proxy to defer tool *schemas*, not just results ⭐ top fit

`docs/comparison.md` and `docs/maximizing-savings.md` already note that
Anthropic's Tool Search Tool does on-demand tool-schema loading **natively for
Claude Code** (verified again this round: 85% reduction, ~77K→~8.7K tokens,
directly observed live in this research session — a batch of MCP tools arrived
as name-only "deferred tools," fetched by schema only on first use). That's a
platform feature, not something quiet-bash needs to build for Claude Code.

The gap: **Codex, Cursor, Gemini CLI, Copilot CLI, and any other MCP client
without native deferred loading get no such benefit.** `proxy/quiet-mcp-proxy.mjs`
already sits on the transport layer and collapses large `tools/call` *results*
(shipped). The same proxy could intercept the `tools/list` response, replace
each tool's full JSON Schema with name + one-line description, cache the full
schemas, and transparently splice the real schema back in on that tool's first
`tools/call` — porting the Tool Search Tool pattern to every non-Claude-Code
client for free.

- **Deterministic, zero LLM calls** — pure request/response rewriting, same
  mechanism as the existing result-collapse.
- **Feasibility: high.** No new dependency; extends code that already exists.
- **Cache caveat (see #2 below):** must be append-only / stable-stub ordering,
  or the schema-splice will itself bust the cache prefix it's trying to protect.

> **Measured (2026-07-05), verdict: do not ship as prototyped.** Built
> `proxy/quiet-mcp-tools-proxy.mjs` (list_tools/get_tool_schema/call_tool
> wrapper) and ran a live A/B (`bench/mcp-schema-deferral.sh`) against a 90-tool
> fake MCP server. The `tools/list` payload shrank 99% as predicted, but real
> session cost was **74% *higher*** for the deferred arm, consistently across
> all reps — the extra `list_tools`→`call_tool` round trip costs more in
> `cache_creation` (priced above 1×) and growing-transcript `cache_read` than
> the schema bytes saved, on a short, few-turn task. Full write-up:
> `bench/RESULTS.md` § "MCP schema-deferral prototype." Only reconsider for
> very long, tool-call-heavy sessions where the extra turn amortizes, or if the
> round-trip itself can be eliminated (client-native support, not a
> transport-layer proxy).

Sources: <https://www.anthropic.com/engineering/advanced-tool-use>,
<https://code.claude.com/docs/en/prompt-caching> (deferred-tools mechanism,
3-0 verified).

### 2. Sandbox-computed result reduction — a distinct category from static preview-folding

Anthropic's "Programmatic/Code-execution tool calling" pattern routes tool
orchestration through a code-execution sandbox so bulky intermediate data (a
10,000-row spreadsheet, a large DB query) is filtered/aggregated *before*
anything reaches the model — 37% token reduction (43,588→27,297) on a complex
research task, with **improved** accuracy (3-0 verified against Anthropic's own
posts, corroborated independently).

This is a real generalization of quiet-bash's "collapse to a static preview"
approach: instead of a fixed folding heuristic, a sandbox computes the *exact*
derived view (filter/aggregate/join) the situation needs. But note the
distinction from quiet-bash's philosophy — Anthropic's version has **the model
write the filtering code**, which reintroduces an LLM call quiet-bash
deliberately avoids. A quiet-bash-shaped version would have to stay mechanical:
e.g., auto-piping a large `curl` JSON response through a fixed `jq` stats
template, or recognizing a handful of known tabular shapes (CSV import, SQL
`SELECT *`) and applying a canned count/sample/aggregate — not general-purpose
code synthesis.

- **Feasibility: medium.** The hard constraint is picking the derived view
  *without* an LLM in the loop; likely only a handful of well-known shapes are
  tractable this way, not a general mechanism.
- **Priority: lower than #1** — flag as an open question, not a committed
  feature.

Sources: <https://www.anthropic.com/engineering/advanced-tool-use>,
<https://www.anthropic.com/engineering/code-execution-with-mcp> (3-0 verified;
a more dramatic "150,000→2,000 tokens, 98.7%" figure for MCP progressive
disclosure was explicitly **refuted** on reverification — don't cite it).

### 3. Cross-file, budget-constrained relevance ranking (Aider repo-map style) — still unbuilt

`docs/token-reduction-research.md` already cites Aider's tree-sitter+PageRank
repo map as prior art for **per-file** signature outlining, which quiet-bash has
since shipped. What's still unbuilt is the *cross-file* piece: Aider ranks
symbols across the **whole repo** by reference graph centrality and packs only
the top-ranked ones into a fixed token budget (default ~1,000 tokens) — a
different problem than "outline this one file I'm reading," closer to
`quiet-map`'s orientation role but at symbol granularity instead of file
granularity (3-0 verified against Aider's own docs, current as of a live
docs.aider.chat cross-check).

- A full tree-sitter dependency would break quiet-bash's zero-dependency
  philosophy. A lighter approximation — import-graph in-degree via
  `grep`/`awk` instead of AST parsing — could capture most of the ranking value
  without the new dependency, but this is unverified and would need its own
  accuracy check before committing to it.
- **Priority: exploratory**, not a committed feature — open question, see below.

---

## Reinforced argument: why deterministic beats LLM-summarization (new evidence)

A single, recent, non-peer-reviewed preprint (treat as provisional, no
independent replication found) measured LLM-driven context
compaction/summarization causing safety-policy violation rates to jump from
**0% (full policy visible) to 30%** across 1,323 test episodes, plus a
demonstrated "Compaction-Eviction Attack" that manipulates an LLM summarizer
into dropping governance constraints on request (2-1 / 3-0 verified). A claimed
training-free fix ("Constraint Pinning," restoring 0% violations) was
**explicitly refuted** — don't cite it.

This is a useful, evidence-backed addition to `docs/comparison.md`'s existing
"deterministic vs LLM-summarization" argument: quiet-bash's lossless/on-disk
approach is structurally immune to this failure mode (nothing is ever
paraphrased away, so there's nothing for an attack to manipulate). Cite as "one
recent study found," not as settled consensus.

---

## Explicitly out of scope (contrast cases, don't build)

- **Squeez-2B** — a released 2B-parameter fine-tuned model for tool-output
  extraction (92% token removal, 0.86 recall / 0.80 F1, reported to beat
  rule-based heuristics). Requires a model inference call — violates
  quiet-bash's zero-model philosophy by definition. Noted for completeness only.
- **TokenPilot** — a cache-aware pruning system claiming 56–87% cost reduction.
  Single non-replicated preprint, benchmarked on the authors' own new
  benchmarks; not confirmed open-source or portable as a bash+jq hook. Watch,
  don't build.

## Reconfirmed baseline (no new action, higher confidence)

- Cache-read tokens are ~10x cheaper (0.1x base price) than fresh input —
  already in `docs/token-savings-research.md` / `docs/speed-research-findings.md`;
  reconfirmed 3-0 this round from two independent Anthropic doc pages. A
  stronger claim ("caching yields 80–90% cost reduction for agentic workflows"
  as a vendor headline) was **refuted** — stick to the 10x per-token figure.
- Naive dynamic pruning/eviction can break the provider's cache prefix if it
  isn't designed to preserve a stable prefix — this is already
  `token-reduction-research.md`'s headline finding; reconfirmed 3-0 / 2-1 this
  round by an independent paper (TokenPilot) and an independent engineering
  blog. A specific supporting figure from another preprint (857 production
  Claude Code sessions, 21.8% "structural waste") was **refuted 0-3** — do not
  cite that number, the underlying point about cache fragility still stands on
  the sources above.
- Deterministic recency-based eviction (pure truncate-oldest-N, no LLM) is a
  real, working technique — Anthropic ships it server-side today
  (`clear_tool_uses_20250919`, oldest-first, placeholder substitution, default
  100K-token trigger). Reconfirmed 3-0. Narrower claims that this *also*
  improves task completion, or that stale tool-state reference causes 47%→11%
  fewer failures, were **refuted** — don't cite those numbers.

---

## Open questions (unresolved by this round)

1. Is deferred tool-schema loading (candidate #1) buildable as a portable
   proxy today, or does it need per-client protocol quirks worked out first
   for Codex/Cursor/Gemini/Copilot specifically?
2. Can a dependency-free approximation of Aider's repo map (ctags or an
   import-graph in-degree heuristic instead of tree-sitter+PageRank) get close
   enough on cross-file relevance ranking to be worth shipping?
3. How much of candidate #2's savings is achievable via a small, fixed set of
   canned filter/aggregate templates (mechanical) versus requiring true
   general-purpose code generation (which would reintroduce a model call)?
4. `bench/session-savings.py` already measures cache-hit rate (commit
   `b84d9b7`) — has anyone run it specifically to check whether quiet-bash's
   *existing* hooks (log-redirect rewrites, value-folding previews) preserve or
   disturb the cached prefix in practice, now that cache fragility has been
   reconfirmed twice?

---

## Refuted this round — do not resurrect

These surfaced during search but failed adversarial verification (2-of-3 or
3-of-3 votes against); excluded from the findings above on purpose:

- Recency-pruning improving task completion (not just cost), and stale-state
  reference causing a 47%→11% failure-rate drop — both from arXiv 2606.10209.
- 857 production Claude Code sessions showing 21.8% structural token waste,
  and the Pichay proxy's 93%-reduction / 0.0254%-fault-rate figures — both from
  arXiv 2603.09023.
- MCP progressive disclosure cutting a task from 150,000→2,000 tokens (98.7%) —
  from Anthropic's code-execution-with-MCP post (the 37%-reduction figure from
  the same source family *did* survive verification and is cited above).
- Anthropic prompt caching being strictly whole-prefix/exact-match with no
  partial caching, and a blanket "80–90% cost reduction" headline for caching —
  both from official Anthropic docs pages (the underlying 0.1x cache-read price
  did survive verification).
- "Constraint Pinning" as a training-free fix restoring safety-violation rates
  to 0% — from the Governance Decay preprint (the 0%→30% violation-rate jump
  itself did survive verification).

## Key sources

- <https://arxiv.org/pdf/2606.10209> — "Less Context, Better Agents" (recency eviction)
- <https://www.anthropic.com/engineering/advanced-tool-use> — Tool Search Tool, Programmatic Tool Calling
- <https://www.anthropic.com/engineering/code-execution-with-mcp> — code-execution-mediated tool results
- <https://platform.claude.com/docs/en/build-with-claude/context-editing> — `clear_tool_uses_20250919`
- <https://aider.chat/2023/10/22/repomap.html> / <https://aider.chat/docs/repomap.html> — tree-sitter + PageRank repo map
- <https://platform.claude.com/docs/en/build-with-claude/prompt-caching>, <https://code.claude.com/docs/en/prompt-caching> — cache pricing/mechanics
- <https://arxiv.org/pdf/2606.22528> — "Governance Decay" (compaction safety-violation jump; single-paper, provisional)
- <https://arxiv.org/pdf/2604.04979> — Squeez-2B (out-of-scope contrast: requires model inference)
- <https://arxiv.org/pdf/2606.17016> — TokenPilot (out-of-scope for now: unreplicated, portability unconfirmed)
