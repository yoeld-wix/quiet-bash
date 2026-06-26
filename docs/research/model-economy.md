# Model economy for coding agents — should quiet-bash have a "simple mode"?

*Research report · June 2026 · for the quiet-bash maintainer*

**One-line answer:** Yes to a *simple mode*, no to a *router*. quiet-bash should never
score a prompt and pick a model itself — that needs a model call or a trained artifact and
risks a documented failure mode. It can, within its principles, (a) emit a cheap, deterministic
*difficulty hint*, and/or (b) generate config that wires up Claude Code's **existing** static
downgrade knobs. The actual model choice stays with the harness.

---

## 1. The landscape: two paradigms, one fork in the road

Everything in "model economy" reduces to two families, and the difference decides whether a
no-model-call tool like quiet-bash can play at all:

| Paradigm | How it works | Quality signal needed | Compatible with quiet-bash? |
|---|---|---|---|
| **Routing** | Look at the query, pick *one* model *before* generating | **ex-ante** — predict quality before the model runs | Only path that *could* fit |
| **Cascading** | Run the cheap model first, *escalate* if the answer looks weak | **post-hoc** — needs a model output to judge | No — inherently requires a model call |

Routing "analyzes each input and selects the most appropriate model based on query
characteristics," a single decision mapping query→model [1]. Cascading instead "operates
sequentially, first attempting inference with smaller, faster models and escalating … only when
the initial response is deemed insufficient" [1][2]. **FrugalGPT** is the canonical cascade:
cheapest-model-first with a learned DistilBERT scorer deciding escalation [3]. The 2025 *Cascade
Routing* work unifies both, formally defining a cascade as "a sequence of routing strategies" [2].

**Why this matters for quiet-bash:** cascading is off the table by construction — judging the
cheap model's output *is* a model call. Only ex-ante routing is even theoretically compatible
with "no model, no network." Hold that thought; §3 shows why even that doesn't survive contact
with the constraints.

## 2. The savings are real — and oversold

The headline numbers are genuine but best-case, dataset-specific, and dependent on trained
artifacts plus in-distribution data:

- **FrugalGPT**: matches GPT-4 with "up to **98%** cost reduction," or +4% accuracy at equal
  cost [3]. But 98% is the top of a 50–98% range on *specific* datasets (HEADLINES / OVERRULING /
  COQA) and needs a labeled in-distribution training corpus.
- **RouteLLM**: "reduce costs by up to **85%** while maintaining 95% GPT-4 performance on … MT
  Bench" [4]. The same routers score only ~45% on MMLU and ~35% on GSM8K — 85% is the
  best-benchmark figure.
- **Cascade routing**: improves cost/accuracy "by up to 8% on RouterBench and by 14% on
  SWE-Bench" over baselines [2].

The field's universal justification: "no single model can optimally address all tasks …
particularly when balancing performance with cost" [5]. True — but the savings need upfront
training data from *your* distribution and degrade off-benchmark. Cite these with the "up to"
hedge; they are not typical-case guarantees.

## 3. The core constraint: cheap heuristics work in theory, nobody ships them alone

This is the load-bearing finding for quiet-bash.

**The good news:** task difficulty *can* be estimated with no model. The survey explicitly lists
"heuristic-based approaches (e.g. text length, word rarity, idiomatic language, syntactic
complexity)" — decades-old NLP techniques needing no model and no artifact [1].

**The catch:** *no surveyed production router actually routes on heuristics alone.* Every shipping
system loads something heavier:

- **RouteLLM** — pre-trained matrix-factorization weights or a fine-tuned BERT classifier (no live
  call), *or* a fine-tuned Llama-3-8B causal classifier (which **is** a live small-model call) [4].
- **semantic-router** (aurelio-labs) — avoids LLM *generation* via vector similarity, but still
  needs an encoder/embedding model (Cohere / OpenAI / HuggingFace / FastEmbed). Not zero-model [6].
- **vLLM Semantic Router** — a local *ModernBERT + LoRA* classifier across 14 categories; a
  fine-tuned ML model, "rather than a cheap heuristic" [7].
- **Morph's router** — a trained classifier, explicitly calling rule-based heuristics "fast but
  inaccurate" [8].
- **UCCI cascade routing** — reads the per-token margin from an *actual small-model generation* —
  a live model call, not a pre-call heuristic [9].

The signal is unambiguous: heuristic-only difficulty estimation is **feasible for a hinting role
but unproven for autonomous model selection**. The people who build routers for a living don't
trust heuristics to make the binding call — so neither should quiet-bash.

## 4. The harness already solves the easy 80%

Claude Code ships the small-task→cheaper-model pattern as **first-class, deterministic,
config-only, no-live-model-call** machinery — which is exactly quiet-bash's bar [10][11]:

- **`haiku` alias** — "Uses the fast and efficient Haiku model for simple tasks," selectable via
  `/model`, `--model`, `ANTHROPIC_MODEL`, or settings [10].
- **`opusplan` alias** — automated *phase-based* routing: Opus during plan mode, Sonnet for
  execution. The trigger is the plan/execution boundary (an internal flag), **not** a model
  deciding mid-task [10].
- **Per-subagent `model:` frontmatter** — `sonnet` / `opus` / `haiku` / `fable` / a full ID /
  `inherit` (default). The built-in Explore/file-discovery subagent already ships pinned to
  Haiku [11].
- **`CLAUDE_CODE_SUBAGENT_MODEL`** — overrides the per-invocation parameter and the frontmatter [10][11].
- **Opus 4.8 `effort` parameter** — five levels (low → max) controlling reasoning depth *per
  request* without switching models — a downgrade lever orthogonal to model choice [12].

All of this resolves through a static precedence chain against an allowlist — no classifier, no
routing-model inference. The docs frame it as a cost lever: "Control costs by routing tasks to
faster, cheaper models like Haiku" [11].

> One contrarian claim — that the `model:` frontmatter is silently ignored when the Agent call
> omits an explicit model (GitHub issue #44385) — was **refuted 0-3** in verification. The static
> config mechanism stands.

**Implication:** the valuable downgrade primitive *already exists* and already meets quiet-bash's
principles. quiet-bash should *delegate to it*, not reimplement it.

## 5. The trap: "routing collapse"

If you were tempted to build a budget-aware learned router anyway, there's a fresh cautionary
result. *When Routing Collapses* (arXiv:2602.03478, Feb 2026) shows that "as the user's cost
budget increases, routers systematically default to the most capable and most expensive model
even when cheaper models already suffice … we term this phenomenon routing collapse" [13].
Empirically, across 11 routing methods the strong-model call frequency converges to ~100% under
large budgets, while an Oracle uses the strongest model for <20% of queries [13].

Root cause — an "objective-decision mismatch": routers predict scalar quality scores, but routing
is a *discrete comparison*, so "small prediction errors can flip relative orderings and trigger
suboptimal selections" [13]. A heuristic that merely *hints* difficulty — leaving the binding
choice to the user's explicit config — sidesteps this entirely.

*(Caveat: this is a single recent preprint, not yet independently replicated. But it's directly
on-point and the verification was unanimous.)*

## 6. Recommendation for quiet-bash

**Build a "simple mode" only as a config/hook layer — never as an in-tool router.** Concretely,
two principle-compatible shapes, in priority order:

**(A) Config helper (lowest risk, highest fit).** A small generator that wires Claude Code's
*existing* static knobs: pin discovery/search/summarize-style subagents to `model: haiku`, suggest
`opusplan`, or set `CLAUDE_CODE_SUBAGENT_MODEL`. This is pure config generation — bash + jq, no
artifact, no model, no network, and it changes no content (lossless). It rides machinery Anthropic
already maintains and benchmarks.

**(B) Deterministic difficulty *hint* (optional, conservative).** A hook that computes a cheap
score from code-appropriate features — diff size, file count, edit-vs-read intent, test presence,
prompt length, token rarity — and *annotates context* with a non-binding "looks small" hint. It
must **only ever suggest downgrade, never upgrade**, and never make the call itself. This respects
the §3 evidence that heuristics are fine for hinting but not for autonomous selection, and the §5
guardrail against collapse.

**Do NOT:** score prompts and select/call a model in-tool (cascading or a learned router). That
breaks zero-dep (needs an artifact/encoder), no-live-model-call (needs a model output to judge),
and lossless, and invites routing collapse.

### Honest open questions before building even (B)

1. **Do NLP heuristics transfer to code?** Length/word-rarity/syntactic-complexity are
   prose-derived. Coding tasks may need different features (diff size, file count, test presence,
   edit vs. read intent). Unvalidated for coding agents specifically.
2. **Is there headroom over the harness's defaults?** What's the measured cost/accuracy of
   `opusplan` / per-subagent Haiku on real coding workloads (e.g. SWE-Bench), and would a
   quiet-bash hint *measurably beat* the static defaults? If not, ship only (A).
3. **Can a hint even be actionable at hook time?** Is model choice already fixed by the time a
   `PreToolUse`/`UserPromptSubmit` hook runs? If so, quiet-bash is limited to config-generation
   (A), not runtime hinting (B). **Verify this in the Claude Code lifecycle before investing in B.**
4. **What guardrail prevents misrouting?** Given collapse, enforce downgrade-only + explicit
   per-task-class opt-in.

---

## Sources

1. *A Survey of Model Routing and Cascading* — arXiv:2603.04445v2 (Apr 2026) *(primary)*
2. *Cascade Routing* — arXiv:2410.10347v3, ICLR 2025 *(primary)*
3. *FrugalGPT* — Chen, Zaharia, Zou (Stanford) — arXiv:2305.05176, TMLR 2024 *(primary)*
4. *RouteLLM* — github.com/lm-sys/RouteLLM, ICLR 2025 *(primary)*
5. *RouterBench* — arXiv:2403.12031 *(primary)*
6. *semantic-router* — github.com/aurelio-labs/semantic-router *(primary)*
7. *vLLM Semantic Router* — github.com/vllm-project/semantic-router *(primary)*
8. *Morph LLM Router* — morphllm.com/llm-router *(blog)*
9. *UCCI cascade routing* — arXiv:2605.18796 (May 2026) *(primary)*
10. *Claude Code — Model configuration* — code.claude.com/docs/en/model-config *(primary, vendor)*
11. *Claude Code — Subagents* — code.claude.com/docs/en/sub-agents *(primary, vendor)*
12. *Claude Opus 4.8 API tutorial* — datacamp.com/tutorial/claude-opus-4-8-api-tutorial *(blog)*
13. *When Routing Collapses* — arXiv:2602.03478 (Feb 2026) *(primary, single preprint)*

**Method:** deep-research harness — 5 search angles → 20 sources fetched → 96 claims extracted →
25 verified by 3-vote adversarial check (24 confirmed, 1 refuted). Caveat: several primary sources
are recent 2026 preprints not yet venue-peer-reviewed; headline savings (98%/85%) are best-case
upper bounds. Note also that "no model call" in the literature usually means "no call to the
expensive *candidate* LLM" — most routers still run a cheap encoder/classifier, which is *stricter*
than quiet-bash's "no model at all" bar.
