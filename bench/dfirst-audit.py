#!/usr/bin/env python3
"""
dfirst-audit — mine agent transcripts for deterministic-first opportunities.

Extends bench/session-savings.py's transcript scan with a sequence model over
tool calls, flagging where the model did tool-shaped work a quiet-bash lever
would do. v1 detectors (high-confidence, structural):
  P4 toolchain probing -> quiet-env   (>=2 version/availability probes in a session)
  P2 unchanged re-read  -> quiet-dedup (Read of a path already Read, no edit since)

Output is candidate DISCOVERY (which lever a real workload needs), NOT a token
number — exact billing stays in bench/run.sh + session-savings.py.

Usage:
  bench/dfirst-audit.py [GLOB] [--top N]      # default GLOB: ~/.claude/projects/*/*.jsonl
"""
import json, glob, os, sys, re

PROBE_RE = re.compile(
    r'(^|\s)(node|python3?|go|rustc|java|ruby|deno|bun|npm|pnpm|yarn|cargo|docker|kubectl)\s+(--version|-v|-version|version)\b'
    r'|(^|;|&&|\|\|)\s*(which|type)\s+\S'
    r'|command\s+-v\s+\S'
)

def events(fp):
    """Yield (name, input_dict) for each tool_use in file order; tolerate junk."""
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
            if isinstance(c, dict) and c.get("type") == "tool_use":
                yield (c.get("name") or "", c.get("input") or {})

def audit(fp):
    probes = 0
    seen, dirty, rereads = set(), set(), 0
    for name, inp in events(fp):
        if not isinstance(inp, dict):
            continue
        if name == "Bash":
            cmd = inp.get("command")
            if isinstance(cmd, str) and PROBE_RE.search(cmd):
                probes += 1
        elif name == "Read":
            p = inp.get("file_path")
            if p:
                if p in seen and p not in dirty:
                    rereads += 1
                seen.add(p); dirty.discard(p)
        elif name in ("Edit", "Write", "MultiEdit"):
            p = inp.get("file_path")
            if p:
                dirty.add(p)
    return probes, rereads

def main():
    top = 20
    pat = None
    a = sys.argv[1:]
    i = 0
    while i < len(a):
        if a[i] == "--top":
            top = int(a[i + 1]); i += 2
        else:
            pat = a[i]; i += 1
    if pat is None:
        pat = os.path.expanduser("~/.claude/projects/*/*.jsonl")

    files = glob.glob(pat)
    tot_probe = tot_reread = sess_probe = sess_reread = 0
    rows = []
    for fp in files:
        pr, rr = audit(fp)
        tot_probe += pr; tot_reread += rr
        if pr >= 2:
            sess_probe += 1
        if rr >= 1:
            sess_reread += 1
        if pr or rr:
            rows.append((os.path.basename(fp), pr, rr))

    print("# deterministic-first audit")
    print(f"scanned {len(files)} transcript(s)")
    print()
    print("| pattern | lever | sessions hit | total occurrences |")
    print("|---|---|--:|--:|")
    print(f"| P4 toolchain probing (>=2/session) | quiet-env | {sess_probe} | {tot_probe} |")
    print(f"| P2 unchanged re-read | quiet-dedup | {sess_reread} | {tot_reread} |")
    print()
    print("Directional candidate-discovery signal (not a token total). A pattern with")
    print("many hits and no shipped lever is the next thing to build.")
    if rows:
        rows.sort(key=lambda r: -(r[1] + r[2]))
        print("\n## top sessions")
        for name, pr, rr in rows[:top]:
            print(f"- {name}: probes={pr} rereads={rr}")

if __name__ == "__main__":
    main()
