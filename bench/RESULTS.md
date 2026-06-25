# quiet-bash benchmark — 2026-06-25T11:11Z

| Layer (real input) | Without | With quiet-bash | Reduction |
|---|--:|--:|--:|
| JSON read · `package-lock.json` (652,257 B) | 163,064 tok | 1,062 tok | **99.3%** |
| Source outline · `pr-review.ts` (162,510 B) | 40,627 tok | 2,144 tok | **94.7%** |
| Command output · `git log -p -12` (162,643 B) | 40,660 tok | 21 tok | **99.9%** |

**Measured total across the layers above: 244,352 tok → 3,227 tok (98.7% reduction).**

Session-level saving is a MODEL, not a single measurable value — it depends on
what fraction of your context is command output / large reads:

    total session saving ≈ (that fraction) × (the per-layer reduction above)

So a session where ~⅓ of context is verbose output lands near ~30% fewer input
tokens; a build/test-heavy session lands higher. The per-layer reductions above
are measured and reproducible; the session % is this multiplication, nothing more.
