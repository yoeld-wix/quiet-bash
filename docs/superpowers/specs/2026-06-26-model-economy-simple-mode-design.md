# quiet-bash "simple mode" — model economy for coding agents

*Design spec · 2026-06-26 · Claude Code target*

## 1. Problem & goal

quiet-bash already economizes the **context** an agent re-sends (losslessly, zero-dep, no model
call). This adds a complementary **model**-economy lever: when a subtask is small enough that a
cheaper model tier handles it, run it on that tier instead of the expensive default — saving cost
**with zero quality regression**.

Hard requirement, proven by benchmark, not asserted: **measured cost savings AND zero regression**
on a checkable task suite, across baseline / A / B arms.

## 2. The contract (non-negotiable principles)

Everything below obeys quiet-bash's existing ethos:

- **No model call, no network** at decision time. Selection is deterministic config or cheap
  heuristics over text quiet-bash already has.
- **Tiers/aliases only, never dated model IDs.** quiet-bash carries *zero* model-version
  knowledge. It emits `haiku`/`sonnet`/`opus`/`opusplan`; the harness owns alias→current-model
  resolution. This is what makes the feature immune to model launches (see §7).
- **Downgrade-only.** Never upgrade a model; only ever route *down* to a cheaper tier. This
  sidesteps the documented "routing collapse" failure mode (see research report
  `docs/research/model-economy.md`).
- **Lossless / reversible.** Changes no content; every config change is plain and undoable.
- **quiet-bash never selects the binding model autonomously from a learned score.** Research
  finding: no production router trusts heuristics alone. quiet-bash either applies *explicit user
  config* (A) or applies a *conservative, downgrade-only heuristic at the one boundary where it's
  mechanically possible* (B), gated on a feasibility spike.

## 3. Feasibility findings (verified against Claude Code docs, 2026-06)

| Capability | Verdict | Consequence |
|---|---|---|
| Hook changes the **main-loop** model | ❌ Impossible — no `model` field in any hook output; main model fixed by `/model`/`--model`/env/settings | Main-loop runtime routing is dead. Drop it. |
| `PreToolUse(Task)` rewrites a **subagent** spawn's `model` via `updatedInput` | ⚠️ Plausible (same mechanism as the existing Bash-command rewrite) but **undocumented** for the `model` key | B is gated on an empirical spike before we commit |
| `additionalContext` carries control fields | ❌ Text only | Can't route via injected context |
| Subagent model precedence | `CLAUDE_CODE_SUBAGENT_MODEL` > per-invocation `model` param > frontmatter `model:` > inherit | A uses frontmatter; B uses the param (which overrides frontmatter — see B guardrail) |
| Aliases version-independent | ✅ on Anthropic API; ⚠️ lag on Bedrock/Vertex/Foundry (Anthropic recommends user pins there) | quiet-bash emits aliases only and stays out of pinning |

## 4. Component A — `model-economy` skill (shippable now)

**What:** a skill (mirrors the existing `skills/minimal-change` pattern) the user invokes. It:

1. Scans the repo's `.claude/agents/*.md`.
2. Classifies each subagent as **safe-to-downgrade** (discovery / search / file-listing /
   summarization intent) vs. **keep** (architecture, complex debugging, multi-file refactor).
   Classification is keyword/role heuristics over the subagent's own description — no model call.
3. For safe-to-downgrade agents lacking an explicit `model:`, **proposes** adding `model: haiku`
   frontmatter (and shows a diff). Applies only on user confirmation.
4. Recommends `opusplan` for the plan/execute phase split where appropriate.

**Properties:** pure config generation; downgrade-only; only ever writes the aliases
`haiku`/`sonnet`/`opus`; fully reversible (it's a frontmatter line); no runtime cost; carries no
model-version knowledge.

**Explicitly NOT:** quiet-bash does **not** set `CLAUDE_CODE_SUBAGENT_MODEL` by default — that env
var is highest-precedence and would force *every* subagent to one model, overriding deliberate
per-agent choices. It may be mentioned as a power-user opt-in, not applied automatically.

**What it does NOT do:** touch the main-loop model, or downgrade a subagent the user pinned.

## 5. Component B — `PreToolUse(Task)` heuristic downgrader (spike-gated)

**Gate first.** Before any B work, run a ~10-minute spike: a `PreToolUse(Task)` hook that
unconditionally rewrites `tool_input.model` to `haiku` via
`hookSpecificOutput.updatedInput`, and confirm (via the resulting session's model) that Claude
Code honors it. **If it doesn't, B is abandoned; ship A alone.**

**If the spike passes — what:** a new adapter `adapters/claude-code-task.sh`, wired as
`PreToolUse` matcher `Task`. On each subagent spawn it:

1. Reads the spawn's prompt/description from `tool_input`.
2. Computes a cheap, deterministic "small task" score from code-appropriate features (intent
   keywords like *search / find / list / grep / summarize*; prompt length; absence of
   *refactor / architect / debug / design*). No model, no network.
3. For a clearly-small spawn **that has no explicit model already in `tool_input`**, rewrites
   `tool_input.model` → `haiku` and returns `permissionDecision: allow` + `updatedInput` (same
   shape the Bash adapter already uses).

**Guardrails:**
- **Downgrade-only:** only ever sets a *cheaper* tier; never raises.
- **Respect explicit choices:** if the spawn already carries a `model`, leave it untouched. (The
  param overrides frontmatter, so blindly writing it would clobber a deliberate `model: opus`
  subagent — forbidden.)
- **Conservative default:** when the heuristic is unsure, do nothing (no downgrade). False
  negatives (missed savings) are acceptable; false positives (downgrading a hard task) are not.

## 6. A/B/baseline benchmark — `bench/model-economy.sh`

Extends the proven `bench/agentic.sh` harness (headless `claude -p`, JSONL records, markdown
table) from 2 arms → 3, and adds a correctness signal (the current bench measures only cost,
because lossless folding can't change answers — model downgrade *can*, so we must grade).

**Arms:**
- `baseline` — no simple mode; subagents inherit the default model.
- `A` — config arm: a fixture repo whose `.claude/agents/*.md` have been tiered by the
  model-economy skill (safe agents → `model: haiku`).
- `B` — hook arm: the `claude-code-task.sh` downgrader active. *Wired only after the §5 spike
  passes; until then the script runs baseline + A.*

**Task suite (new, delegation-inducing):** a small set of tasks engineered so the main agent
*spawns search/summary subagents* (the only thing A and B affect), each with a **deterministic
assertion** — a known-correct fact the final answer must contain (grep/regex). Example shape:
"Find which file defines `X` and report the function that exports it" → assert the answer contains
the known symbol/file. Zero-dep grading, no judge model.

**Metrics per (arm, task, repeat):** input/output tokens, cost $, time, turns (as today) **plus
`pass` (bool)** from the assertion.

**Report:** mean cost/tokens per arm **and pass-rate per arm**. Success criterion stated up front:
**A (and B, if shipped) pass-rate == baseline pass-rate (zero regression), at strictly lower
cost.** If pass-rate drops, the arm fails — savings don't count.

**Caveat carried into RESULTS.md:** agent behavior is variable (the existing bench already notes
high run-to-run variance); report repeats and means, and treat a single bad run as noise only if
pass-rate holds.

## 7. Versioning strategy (the original concern, resolved)

The feature must not rot when a new model ships. Resolution:

- quiet-bash references **only tier aliases** (`haiku`/`sonnet`/`opus`/`opusplan`). On the
  Anthropic API these always resolve to the current generation — so `model: haiku` written today
  is still correct after the next Haiku release, with **no quiet-bash change required**.
- On Bedrock/Vertex/Foundry, aliases lag and Anthropic recommends users pin via
  `ANTHROPIC_DEFAULT_*`. quiet-bash **does not manage pins** — it emits the alias and documents
  that on those clouds the user's own pin governs resolution. This keeps quiet-bash's
  zero-model-knowledge property intact.
- Consequence: there is **no model table, no version list, nothing to update** in quiet-bash when
  models change. The maintenance burden is zero by construction.

## 8. Out of scope (YAGNI)

- Cascading / escalation (needs a model output to judge — violates no-model-call).
- A learned/embedding router (needs an artifact — violates zero-dep; risks routing collapse).
- Main-loop model switching (mechanically impossible via hooks).
- Non-Claude-Code agents (Codex/Gemini/…) — deferred; the tier abstraction generalizes to the
  adapter layer later, but first prove it on Claude Code.
- Auto-setting `CLAUDE_CODE_SUBAGENT_MODEL`.

## 9. Risks & open items

- **B may be infeasible** — mitigated by the spike gate; A ships regardless.
- **Heuristic transfer to code** — prose NLP difficulty features may misjudge coding subtasks;
  mitigated by downgrade-only + conservative-when-unsure + the regression benchmark catching it.
- **Benchmark cost/variance** — running 3 arms × tasks × repeats against real models costs tokens
  and is noisy; mitigated by a small task suite, repeats, and pass-rate as the gating metric.

## 10. Sequencing

1. Build the benchmark harness (`bench/model-economy.sh`) with baseline + A arms and the
   delegation-inducing task suite + assertions.
2. Build Component A (`model-economy` skill); measure baseline vs A → must show zero regression +
   cost savings.
3. Run the B feasibility spike. If it passes: build Component B, add the B arm, re-measure. If it
   fails: document the negative result and ship A.
4. Update `bench/RESULTS.md` and README with measured numbers.
