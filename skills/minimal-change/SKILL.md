---
name: minimal-change
description: Use before writing, adding, or changing code for any feature or fix. Guides toward the smallest correct solution — reuse before rewrite, existing tools before new dependencies, fewer lines and files — to cut generated output tokens (the 3–5×-priced, serially-generated half of cost) without ever trimming correctness, validation, security, or tests.
---

# Write the Smallest Correct Change

quiet-bash's hooks cut the **input** you re-send every turn. This is the other
half: the **output** the model generates — billed ~3–5× input and produced one
token at a time, so it drives both cost and latency. Less code generated means a
cheaper, faster turn — and less to read, test, and maintain afterward.

The target is the **smallest change that fully solves the problem you actually
understand**. Small is not the goal by itself: a tiny diff in the wrong place,
or a tiny diff that's subtly broken, costs far more than it saves.

## Understand before you shrink
Read the request and the code it touches, and follow the real flow, before
picking an approach. Minimizing a change you haven't understood is how the
second bug ships.

## Reach for the least first
Go down this list only until something *fully* solves it:
- **Don't build it** if it isn't needed yet — skip speculative structure and
  abstractions nobody asked for.
- **Reuse** a helper or pattern already in this repo before writing a new one.
- **Use the standard library or platform** before reaching for a dependency.
- **Use a dependency that's already installed** before adding another.
- Then write the **fewest lines that work** — prefer deleting to adding, boring
  to clever, fewer files to more.

For a bug, fix the shared root cause once rather than patching each caller.

## The no-regression floor (never shrink these)
Cutting code must never cut correctness. Always keep: input validation at trust
boundaries, error handling that prevents data loss, security, accessibility, and
anything explicitly requested. Leave one small runnable check behind for
non-trivial logic. If you knowingly take a shortcut, name its limit in a one-line
comment.

---
*Inspired by the open-source **ponytail** project (MIT), which delivers this idea
as a dedicated cross-agent tool. If you want it always-on across every agent,
install ponytail; this skill is quiet-bash's lightweight, in-repo take.*
