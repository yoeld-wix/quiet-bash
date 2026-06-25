# How quiet-bash compares — and what stacks with it

A field map of agent cost/latency reducers, by *what they cut* and *how*.
Honest labels: **measured** = we ran it; **claimed** = the project's own
benchmark; **modeled** = an estimate, not measured end-to-end.

## The categories

Cost has distinct sources, and each tool attacks a different one — which is why
several **stack** instead of competing:

| Source of cost | Who attacks it |
|---|---|
| **Input** re-sent every turn (command output, file reads) | **quiet-bash** (hooks) |
| **Output** prose the model generates | **Concise** output style |
| **Code** the model writes | **minimal-change** skill / **ponytail** |
| **History** bloat (old tool results) | Anthropic context-editing |
| **Tool schemas** re-sent every turn | Anthropic Tool Search (`defer_loading`) |
| **Re-processing** the stable prefix | Anthropic prompt caching |

## The comparison

| Approach | Cuts | Mechanism | Lossless? | Regression risk | Savings | Stacks w/ quiet-bash? |
|---|---|---|---|---|---|---|
| **quiet-bash** | input (tool output, reads) | mechanical (hook/wrapper/proxy) | **Yes** — full payload spilled byte-exact | **None** | 90–99.9% per op *(measured)*; ~30% session *(modeled)* | — |
| **Concise** output style | output prose | behavioral (system prompt) | n/a (style) | Low (no-loss guardrails) | ~10% faster *(measured)* | yes |
| **minimal-change** skill | code written | behavioral (skill) | n/a | Low (no-regression floor) | ~45% less code *(measured A/B)* | yes |
| **Concise + minimal-change** | output + code | behavioral | n/a | Low | ~30% midpoint / ~49% high-end on coding turns *(measured A/B)* | yes |
| **ponytail** | code written | behavioral (rules across 14 agents) | n/a | Low (guardrails) | ~54% less code, ~20% cost, ~27% time *(claimed)* | **yes — complementary** |
| Anthropic **prompt caching** | prefix re-processing | provider | Yes | None | cache reads 0.1× input *(docs)* | yes |
| Anthropic **context-editing** | old tool results | provider | recoverable (placeholder) | Low | up to ~84% on long tool-heavy runs *(claimed)* | yes |
| Anthropic **Tool Search** | tool schemas | provider | Yes (on-demand load) | Low | 55k→stub for multi-server *(docs)* | yes |
| **Model routing** (Haiku for simple) | per-call price | route to cheaper model | No | **Medium–High** (quality) | large, but quality-dependent | partial |
| **LLMLingua** prompt compression | input tokens | extra LLM, drops tokens | **No** | **High** for code/logs | up to 20× *(claimed)*, lossy | no (off the lossless path) |
| **Rust/compiled rewrite** | hook startup ms | native binary | n/a | n/a | 12–27× on the outliner *(measured)* — **invisible vs LLM turn** | rejected (kills zero-dep) |
| **Persistent daemon** | per-call startup | warm socket | n/a | Med (stale-daemon footguns) | ~10–15 ms *(researched)* — invisible | rejected (complexity) |

## quiet-bash vs ponytail (the closest pairing)

They're often confused as alternatives; they're **opposites that combine**:

| | quiet-bash | ponytail |
|---|---|---|
| Attacks | **input** (what re-enters context) | **output** (what the model writes) |
| Mechanism | mechanical hooks/proxy | behavioral rules/prompt |
| Lossless | yes (byte-exact spill) | n/a (changes what's built) |
| Delivery | hooks + shell wrapper + MCP proxy | rules/skills across 14 agents |
| Best for | log/read-heavy sessions | code-generation-heavy sessions |
| Together | **input + output covered** — disjoint categories, no overlap |

quiet-bash ships its own *inspired-by* output skill (`minimal-change`) for users
who want one tool; ponytail is the dedicated, always-on, cross-agent version.
**Run both for full coverage.**

## Bottom line
- The **lossless, no-regression** frontier: quiet-bash (input) + Concise +
  minimal-change/ponytail (output) + native caching/context-editing/Tool Search
  (history & schemas). These stack across disjoint cost sources.
- **Off the frontier** (trade accuracy or identity): model routing, LLMLingua,
  Rust/daemon rewrites — included for completeness, not recommended as defaults.
