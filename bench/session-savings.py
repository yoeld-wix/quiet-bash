#!/usr/bin/env python3
"""
Measure quiet-bash's session-level saving on REAL agent transcripts.

The per-operation reductions (bench/run.sh) are exact. The session-level number
depends on how much of a session is large tool output — so instead of modelling
it, this measures it on actual Claude Code session logs.

For each session .jsonl it sums the bytes of every tool result that entered the
context, finds the ones quiet-bash would collapse (tool results over the size
threshold), and reports what fraction of the session's text those represent.
That fraction × ~99% (the measured per-op cut) is the one-time saving; the real
saving is higher because the agent is stateless and re-sends that text every
later turn (not counted here — this is a conservative floor).

Usage:
  bench/session-savings.py [GLOB]      # default: ~/.claude/projects/*/*.jsonl
  QUIET_RESULT_MIN_BYTES=25000 bench/session-savings.py
"""
import json, glob, os, sys, statistics

THRESH = int(os.environ.get("QUIET_RESULT_MIN_BYTES", "25000"))
SUMMARY_BYTES = 300          # what quiet-bash leaves behind per collapsed result
MIN_SESSION_BYTES = 20000    # ignore trivial sessions (a few messages)

def text_len(x):
    """bytes of a tool_result/message content that's a str or list of text parts."""
    if isinstance(x, str):
        return len(x.encode("utf-8", "ignore"))
    if isinstance(x, list):
        n = 0
        for p in x:
            if isinstance(p, dict):
                n += len((p.get("text") or "").encode("utf-8", "ignore"))
            elif isinstance(p, str):
                n += len(p.encode("utf-8", "ignore"))
        return n
    return 0

def analyze(fp):
    total = 0          # all text bytes that entered context
    quietable = 0      # bytes in tool results over threshold
    nq = 0             # how many such results
    for ln in open(fp, errors="ignore"):
        ln = ln.strip()
        if not ln:
            continue
        try:
            o = json.loads(ln)
        except Exception:
            continue
        msg = o.get("message") or {}
        content = msg.get("content") if isinstance(msg, dict) else None
        parts = content if isinstance(content, list) else ([content] if content else [])
        for c in parts:
            if isinstance(c, dict) and c.get("type") == "tool_result":
                sz = text_len(c.get("content"))
                total += sz
                if sz > THRESH:
                    quietable += sz
                    nq += 1
            elif isinstance(c, dict) and c.get("type") == "text":
                total += text_len(c.get("text"))
            elif isinstance(c, str):
                total += len(c.encode("utf-8", "ignore"))
    return total, quietable, nq

def main():
    pat = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.claude/projects/*/*.jsonl")
    files = glob.glob(pat)
    fracs, pooled_total, pooled_quiet, big = [], 0, 0, 0
    for fp in files:
        try:
            total, quietable, nq = analyze(fp)
        except Exception:
            continue
        if total < MIN_SESSION_BYTES:
            continue
        big += 1
        saved = max(0, quietable - nq * SUMMARY_BYTES)
        fracs.append(100.0 * saved / total)
        pooled_total += total
        pooled_quiet += saved

    if not fracs:
        print("no sessions matched"); return
    fracs.sort()
    def pct(p): return fracs[min(len(fracs)-1, int(p/100*len(fracs)))]
    print(f"# quiet-bash session saving — measured on {big} real sessions")
    print(f"#   (threshold {THRESH} B, glob {pat})\n")
    print(f"  pooled (all bytes):   {100.0*pooled_quiet/pooled_total:5.1f}%  of context bytes were large tool output quiet-bash collapses")
    print(f"  median session:       {statistics.median(fracs):5.1f}%")
    print(f"  mean session:         {statistics.mean(fracs):5.1f}%")
    print(f"  p75 / p90 session:    {pct(75):5.1f}% / {pct(90):5.1f}%")
    print(f"  sessions with >0 cut:  {sum(1 for f in fracs if f>0)}/{big}")
    print("\nOne-time floor (not counting per-turn re-send, which raises it). The")
    print("~99% per-op cut is measured separately by bench/run.sh.")

if __name__ == "__main__":
    main()
