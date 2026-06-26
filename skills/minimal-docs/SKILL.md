---
name: minimal-docs
description: Use before writing or editing any markdown the agent generates — READMEs, docs/, design specs, CHANGELOG, PR descriptions. Guides toward fewer rows in .md files (link don't duplicate, one example not three, table over paragraph, cut filler) to save generated output tokens (the 3–5×-priced, serially-generated half of cost) — without ever dropping install steps, warnings, accuracy, copy-pasteable commands, or detail the reader needs.
---

# Write the Fewest Rows That Fully Document It

quiet-bash's hooks cut the **input** you re-send every turn. This is the
output-side, prose edition: the markdown the model *generates* is billed ~3–5×
input, produced one token at a time, and re-read on every later turn. Fewer rows
means a cheaper, faster turn — and less for the reader to wade through and you to
maintain.

The target is the **fewest rows that fully document what the reader needs**. Short
is not the goal by itself: a terse doc that omits a required step, or buries the
one fact the reader came for, costs far more than it saves.

## The no-regression floor (never shrink these)
Cutting rows must never cut substance. Always keep:
- install / setup / run steps,
- required warnings and security or accuracy caveats,
- copy-pasteable commands and config (exact, not paraphrased),
- anything the user explicitly asked to document.

Concise means cutting **filler, not detail**. When brevity and clarity conflict,
clarity wins — a clear sentence beats a cryptic fragment.

## Understand before you shrink
Know the doc's audience and purpose first. Terseness in the wrong place loses
readers; trimming a section you haven't understood is how the missing step ships.

## Reach for the least first
Go down this list until the doc is complete:
- **Don't write** sections nobody asked for — no speculative FAQs, no restating
  the obvious, no closing summary that repeats the intro.
- **Link** to an existing doc instead of duplicating its content.
- **One** good example beats three near-identical ones.
- **Table or list** instead of a paragraph when the content is structured.
- **Cut** hedging, filler, and narration of obvious steps.
- When two phrasings carry the same information, choose the shorter one.

---
*Inspired by the open-source **ponytail** project (MIT), which delivers this idea
as a dedicated cross-agent tool. This skill is quiet-bash's lightweight, in-repo
take — the prose sibling of `minimal-change` (which trims generated code).*
