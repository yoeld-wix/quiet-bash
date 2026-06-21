# Token Savings Research

quiet-bash saves tokens by keeping verbose command output out of the agent's
conversation context. It does not make every token in a session disappear; it
removes the command-output slice before that slice can be re-sent, cached,
compacted, or billed.

## What The Benchmark Shows

The current benchmark in this repo measured or modeled 10 verbose commands:

| Scenario | Without quiet-bash | With quiet-bash | Reduction |
|---|--:|--:|--:|
| All benchmark commands | 536,957 tokens | 250 tokens | 99.953% |
| Average verbose command | 53,696 tokens | 25 tokens | 99.953% |

The estimate uses `bytes / 4` as the token approximation. That is coarse, but
the gap is large enough that tokenizer differences do not change the conclusion:
large logs become one-line summaries.

## Session-Level Estimate

The practical rule is:

```text
total token saving ~= command-output share of context x 99.953%
```

| Workflow | Assumed command-output share | Estimated total token saving |
|---|--:|--:|
| Light reading/editing | 15-20% | ~15-20% |
| Typical test/build loops | 30-40% | ~30-40% |
| Heavy TDD/CI debugging | 50-60% | ~50-60% |

The README's `~30%` typical-session claim is therefore reasonable if command
output is roughly a third of the conversation context. It should be presented as
a representative model, not a guarantee.

## How This Interacts With Prompt Caching

Provider prompt caching reduces the cost and latency of repeated input prefixes,
but the repeated tokens still have to exist in the prompt. quiet-bash acts
earlier: it prevents huge command outputs from entering the conversation in the
first place.

Relevant provider docs:

- OpenAI says prompt caching can reduce latency by up to 80% and input token
  costs by up to 90%, and that cache hits depend on exact prefix matches:
  <https://developers.openai.com/api/docs/guides/prompt-caching>
- Anthropic says Claude Code token costs scale with context size, and recommends
  context management, hooks, and other preprocessing to reduce token usage:
  <https://code.claude.com/docs/en/costs>
- Anthropic prompt caching prices cache reads at `0.1x` base input-token cost,
  with higher-cost cache writes, so caching helps repeated context but does not
  replace removing unnecessary log text:
  <https://platform.claude.com/docs/en/build-with-claude/prompt-caching>

## Best Claim To Use Publicly

Recommended wording:

> In a 10-command benchmark, quiet-bash cut command-output tokens from 536,957
> to about 250, a 99.953% reduction for that output. Total session savings
> depend on how log-heavy the workflow is; a typical test/build session can land
> around 30% fewer input tokens.

Avoid claiming that quiet-bash reduces the entire bill by 99.9%. That number is
true for command output in the benchmark, not for total session spend.
