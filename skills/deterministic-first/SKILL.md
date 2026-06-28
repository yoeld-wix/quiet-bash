---
name: deterministic-first
description: Use before reading files or large output to find, count, extract, parse, verify, loop, or wait. Routes that work to a deterministic shell pipeline so the answer enters context, not the haystack — cheaper and more correct than reading content into the model.
---

# Pipe for the Answer, Don't Read the Haystack

quiet-bash's hooks shrink output you already chose to read. This is the other
move: change the *choice*. A human debugging a 10k-line log doesn't read it into
their head — they pipe `grep | sort | uniq -c`. The shell is cheaper (no tokens
for the haystack, none to re-send it every later turn) and more correct (a
`uniq -c` count doesn't hallucinate; a regex doesn't skim past line 4,000).

## The decision rule
Before issuing a Read / `cat` / large fetch **whose purpose is to locate or
compute something**, ask: *can a pipeline return just the answer?* If yes, run
the pipeline and let only the answer enter context.

| Task | Read-to-answer (avoid) | Deterministic form |
|---|---|---|
| **Find** where / which files | open files until you spot it | `rg -l PAT` · `rg -n PAT` · `grep -rln PAT` |
| **Count** / frequency | read log, tally by eye | `grep -c PAT` · `quiet-agg FILE 'PAT'` |
| **Extract** fields | copy values out of JSON/text | `jq '.field'` · `awk '{print $2}'` · `grep -oE` |
| **Parse** structured slices | scan a config visually | `jq` / `yq` / `quiet-query FILE keys` |
| **Verify** a fact | read output to confirm | `quiet-verify FILE 'PAT'` · `test -f` · exit code |
| **Repeat** over a set | N near-identical tool calls | `xargs` · `for f in …; do …; done` |
| **Wait** for a condition | poll by re-reading status | `until COND; do sleep N; done` |

## Compose with quiet-bash
When the haystack is a quiet-bash spill (`[ok: … hidden in <path>]` or a
`spilled to <path>` line), run the pipeline **against that file** —
`grep`/`jq`/`quiet-query <path>`/`quiet-verify <path> …`/`quiet-agg <path> …`.
You recover the exact answer without ever re-reading the haystack.

## The no-regression floor
Never trade correctness for a pipeline. If you genuinely need the full content —
reviewing prose, understanding unfamiliar code, any case where *you* are the
right judge — **read it**. A pipeline that misses the thing you needed costs far
more than it saves. This reflex is for *find / compute*, not for *understand*.
When a pattern might miss matches (case, word boundaries, multiline), widen it
or fall back to reading.
