# Design: `minimal-docs` skill

## Problem
quiet-bash's hooks trim the **input** side (re-sent tool output, file reads). The
output side — tokens the model *generates*, billed ~3–5× input and produced
serially — is covered for chat (`Concise` style) and code (`minimal-change`
skill) but not for **prose written to disk**. Agents routinely over-write
markdown: redundant sections, three examples where one suffices, hedging,
paragraphs that should be tables. Those rows cost generation tokens now and
re-reading tokens on every later turn.

## Goal
A new standalone skill, `minimal-docs`, that steers the agent to write **fewer
rows in markdown files** it generates or edits — concise but complete — as the
prose sibling of `minimal-change`.

## Non-goals
- No hook/automation. It is a skill, invoked like `minimal-change`.
- No new benchmark in this iteration (can be added later).
- Does not replace the `Concise` output style (that governs chat responses, not
  files on disk) or `minimal-change` (code, not prose).

## Scope
Applies before writing or editing **any markdown the agent generates**: READMEs,
`docs/`, design specs, CHANGELOG, PR descriptions.

## Design

### File
`skills/minimal-docs/SKILL.md` — same structure as `skills/minimal-change/SKILL.md`.

### Frontmatter
- `name: minimal-docs`
- `description:` trigger fires *before writing/editing any markdown file*; frames
  it as cutting generated output tokens (the 3–5×-priced, serial half of cost)
  without dropping required detail.

### Body sections (in order)
1. **Framing** — output side, prose edition. Fewer rows = cheaper, faster turn +
   less to re-read and maintain. Reference quiet-bash input/output split.
2. **The no-regression floor (never shrink these)** — *placed first / most
   prominent* per user direction. Never drop: install/setup steps,
   required warnings, security & accuracy caveats, copy-pasteable commands, and
   anything the user explicitly asked for. Concise = cut filler, not detail.
   Clarity beats brevity when they conflict.
3. **Understand before you shrink** — know the doc's audience and purpose first;
   terseness in the wrong place loses readers.
4. **Reach for the least first** — prose levers, in order: don't write sections
   nobody asked for · link instead of duplicating · one good example over three ·
   table/list over paragraph · cut hedging, filler, and restating · when two
   phrasings carry the same info, pick the shorter.
5. **ponytail attribution** — same footer style as `minimal-change`.

### README
Add a short entry under the "Output side" section (after the `minimal-change`
entry, ~line 388 of `README.md`) so the three output-side tools sit together:
`Concise` style · `minimal-change` skill · `minimal-docs` skill. Add a TOC line
under the existing output-side TOC entries (~line 75).

## Success criteria
- `skills/minimal-docs/SKILL.md` exists, parses, and reads as a clear sibling of
  `minimal-change` with the no-regression floor foremost.
- README discoverability entry + TOC line added.
- The skill itself is concise (dogfoods its own rule).
