#!/usr/bin/env bash
#
# quiet-bash test suite. Runs in CI and locally:  bash tests/run.sh
# Exits non-zero if any assertion fails.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

echo "== core: should WRAP =="
. "$ROOT/core/quiet-core.sh"
for c in "yarn test" "pnpm run build" "bun test" "pytest -q" "cargo build --release" \
         "go test ./..." "mvn package" "./gradlew test" "docker compose up" "make" \
         "cmake --build ." "ninja" "jest" "eslint . --fix" "tsc -p ." "uv sync" \
         "git diff" "git log" "git show HEAD"; do
  if quiet_rewrite "$c" >/dev/null; then pass "wrap: $c"; else bad "should wrap: $c"; fi
done

echo "== core: should PASS THROUGH =="
for c in "ls -la" "cat f.txt" "grep -r x ." "git status" "gh pr list" "echo hi" "pwd" \
         "cd /tmp" "which node" "git diff --stat" "git log --oneline" "yarn info x"; do
  if quiet_rewrite "$c" >/dev/null; then bad "should pass: $c"; else pass "pass: $c"; fi
done

echo "== adapters: output shape for 'yarn test' + passthrough for 'ls -la' =="
EV='{"tool_input":{"command":"yarn test"}}'
PE='{"tool_input":{"command":"ls -la"}}'

shape() { # adapter  jqpath  name
  local got
  got=$(printf '%s' "$EV" | "$ROOT/adapters/$1" | jq -r "$2" 2>/dev/null)
  [ -n "$got" ] && [ "$got" != "null" ] && pass "$3 wraps" || bad "$3 wrap shape ($2)"
  got=$(printf '%s' "$PE" | "$ROOT/adapters/$1")
  [ -z "$got" ] && pass "$3 passes through" || bad "$3 should pass through"
}
# Codex & Gemini send the command under .tool_input.command (real schema).
shape claude-code.sh '.hookSpecificOutput.updatedInput.command'        "claude-code"
shape codex.sh       '.hookSpecificOutput.updatedInput.command'        "codex"
shape gemini.sh      '.hookSpecificOutput.tool_input.command'          "gemini"
[ "$(printf '%s' "$EV" | "$ROOT/adapters/codex.sh" | jq -r '.hookSpecificOutput.permissionDecision')" = "allow" ] && pass "codex allow" || bad "codex allow"

# Copilot uses the REAL documented payload: toolArgs is a JSON-encoded STRING.
CEV='{"toolName":"bash","toolArgs":"{\"command\":\"yarn test\"}"}'
CPE='{"toolName":"bash","toolArgs":"{\"command\":\"ls -la\"}"}'
co=$(printf '%s' "$CEV" | "$ROOT/adapters/copilot.sh")
[ "$(printf '%s' "$co" | jq -r '.modifiedArgs.command' 2>/dev/null | head -c1)" != "" ] && pass "copilot parses toolArgs string + wraps" || bad "copilot toolArgs parse"
[ "$(printf '%s' "$co" | jq -r '.permissionDecision' 2>/dev/null)" = "allow" ] && pass "copilot allow" || bad "copilot allow"
[ -z "$(printf '%s' "$CPE" | "$ROOT/adapters/copilot.sh")" ] && pass "copilot small passes through" || bad "copilot passthrough"
# snake_case alias also accepted
[ -n "$(printf '%s' '{"tool_input":{"command":"yarn test"}}' | "$ROOT/adapters/copilot.sh" | jq -r '.modifiedArgs.command' 2>/dev/null)" ] && pass "copilot snake_case alias" || bad "copilot alias"

echo "== shims: wrap / passthrough via PATH =="
TMP=$(mktemp -d)
mkdir -p "$TMP/realbin" "$TMP/shims"
printf '#!/usr/bin/env bash\necho l1; echo l2; echo l3\n' > "$TMP/realbin/pytest"
printf '#!/usr/bin/env bash\necho "yarn $*"\n' > "$TMP/realbin/yarn"
chmod +x "$TMP/realbin/pytest" "$TMP/realbin/yarn"
"$ROOT/adapters/install-shims.sh" "$TMP/shims" >/dev/null
export PATH="$TMP/shims:$TMP/realbin:$PATH"
out=$(timeout 10 pytest </dev/null);              echo "$out" | grep -q '^\[ok' && pass "shim pytest wraps"       || bad "shim pytest wrap"
out=$(timeout 10 pytest --version </dev/null);    { ! echo "$out" | grep -q '^\[ok'; } && echo "$out" | grep -q 'l1' && pass "shim --version passes" || bad "shim --version pass"
out=$(timeout 10 yarn install </dev/null);        echo "$out" | grep -q '^\[ok' && pass "shim yarn install wraps" || bad "shim yarn install wrap"
out=$(timeout 10 yarn info x </dev/null);          echo "$out" | grep -q '^yarn info x' && pass "shim yarn info passes" || bad "shim yarn info pass"
rm -rf "$TMP"

echo "== JSON read optimization =="
JTMP=$(mktemp -d)
big="$JTMP/big.json"; small="$JTMP/small.json"
jq -n '{name:"x", items:[range(3000)|{id:.,name:"pkg",version:"1.0.0",resolved:"https://example.com/x"}]}' > "$big"
jq -n '{name:"x", version:"1.0.0"}' > "$small"
# large plain read -> wrapped to the summarizer
if quiet_rewrite "cat $big" | grep -q 'quiet-json.sh'; then pass "large cat *.json -> summarizer"; else bad "large cat *.json wrap"; fi
# small json -> pass through
if quiet_rewrite "cat $small" >/dev/null; then bad "small json should pass"; else pass "small json passes through"; fi
# jq projection -> pass through (don't fight an explicit query)
if quiet_rewrite "jq '.items[0]' $big" >/dev/null; then bad "jq projection should pass"; else pass "jq projection passes through"; fi
# piped command -> pass through
if quiet_rewrite "cat $big | jq ." >/dev/null; then bad "piped json should pass"; else pass "piped json passes through"; fi
# summarizer actually shrinks + stays valid-ish + shows totals
sout=$("$ROOT/core/quiet-json.sh" "$big")
rawb=$(wc -c <"$big"|tr -d ' '); sumb=$(printf '%s' "$sout"|wc -c|tr -d ' ')
[ "$sumb" -lt "$((rawb/10))" ] && pass "summary <10% of raw ($sumb vs $rawb)" || bad "summary not small enough"
echo "$sout" | grep -q 'more of 3000' && pass "summary states total count" || bad "summary missing total count"
echo "$sout" | grep -q 'quiet-json.sh' >/dev/null; echo "$sout" | grep -q 'jq ' && pass "summary has jq drill-in footer" || bad "summary missing footer"
rm -rf "$JTMP"

echo "== YAML read optimization =="
if command -v ruby >/dev/null 2>&1 || command -v yq >/dev/null 2>&1 \
   || { command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; }; then
  YT=$(mktemp -d)
  bigy="$YT/big.yaml"; smally="$YT/small.yaml"
  { echo "items:"; for i in $(seq 1 700); do printf -- '  - {id: %s, name: pkg, version: 1.0.0, url: "https://example.com/x"}\n' "$i"; done; } > "$bigy"
  printf 'name: x\nversion: 1.0.0\n' > "$smally"
  if quiet_rewrite "cat $bigy" | grep -q 'quiet-json.sh'; then pass "large cat *.yaml -> summarizer"; else bad "large yaml wrap"; fi
  if quiet_rewrite "cat $smally" >/dev/null; then bad "small yaml should pass"; else pass "small yaml passes through"; fi
  if quiet_rewrite "yq '.items[0]' $bigy" >/dev/null; then bad "yq projection should pass"; else pass "yq projection passes through"; fi
  yout=$("$ROOT/core/quiet-json.sh" "$bigy")
  echo "$yout" | grep -q 'YAML' && pass "yaml summary labeled YAML" || bad "yaml summary label"
  echo "$yout" | grep -q 'more of 700' && pass "yaml summary states total count" || bad "yaml total count"
  rawb=$(wc -c <"$bigy"|tr -d ' '); sumb=$(printf '%s' "$yout"|wc -c|tr -d ' ')
  [ "$sumb" -lt "$((rawb/3))" ] && pass "yaml summary shrinks ($sumb vs $rawb)" || bad "yaml summary not small"
  rm -rf "$YT"
else
  echo "  (skipped — no YAML converter: ruby / python3+PyYAML / yq)"
fi

echo "== MCP result optimization (Claude Code PostToolUse) =="
MCP="$ROOT/adapters/claude-code-mcp.sh"
# large JSON result → replaced with a collapsed summary
bigjson=$(jq -nc '{items:[range(3000)|{id:.,name:"pkg",version:"1.0.0",url:"https://example.com/x"}]}')
pj=$(jq -n --arg t "$bigjson" '{tool_name:"mcp__search__query", tool_response:{content:[{type:"text",text:$t}]}}')
oj=$(printf '%s' "$pj" | "$MCP")
rep=$(printf '%s' "$oj" | jq -r '.hookSpecificOutput.updatedToolOutput.content[0].text' 2>/dev/null)
[ -n "$rep" ] && echo "$rep" | grep -q 'quiet-mcp' && pass "large JSON MCP result replaced" || bad "mcp json replace"
[ "${#rep}" -lt "${#bigjson}" ] && pass "mcp summary smaller than raw (${#rep} < ${#bigjson})" || bad "mcp json not smaller"
echo "$rep" | grep -q 'more of 3000' && pass "mcp json collapses repeated shape" || bad "mcp json collapse"
# large TEXT result → spilled with head/tail
bigtext=$(for i in $(seq 1 4000); do echo "log line $i: something happened here with detail"; done)
pt=$(jq -n --arg t "$bigtext" '{tool_name:"mcp__web__fetch", tool_response:{content:[{type:"text",text:$t}]}}')
ot=$(printf '%s' "$pt" | "$MCP" | jq -r '.hookSpecificOutput.updatedToolOutput.content[0].text' 2>/dev/null)
echo "$ot" | grep -q 'spilled to' && echo "$ot" | grep -q 'first 20 lines' && pass "large text MCP result spilled + head/tail" || bad "mcp text spill"
# small result → pass through (no output)
ps=$(jq -n '{tool_name:"mcp__x__y", tool_response:{content:[{type:"text",text:"tiny result"}]}}')
[ -z "$(printf '%s' "$ps" | "$MCP")" ] && pass "small MCP result passes through" || bad "mcp small passthrough"
# already-wrapped → no double wrap
pw=$(jq -n --arg t "[quiet-mcp] already done $bigtext" '{tool_name:"mcp__x__y", tool_response:{content:[{type:"text",text:$t}]}}')
[ -z "$(printf '%s' "$pw" | "$MCP")" ] && pass "no double-wrap of quiet-mcp output" || bad "mcp double-wrap guard"
# non-text content (image) → pass through
pi=$(jq -n '{tool_name:"mcp__x__y", tool_response:{content:[{type:"image",data:"AAAA"}]}}')
[ -z "$(printf '%s' "$pi" | "$MCP")" ] && pass "non-text MCP content passes through" || bad "mcp non-text passthrough"

echo
[ "$fail" -eq 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
