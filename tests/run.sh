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

echo "== core: gh + recursive-listing layers =="
for c in "gh run view 123 --log" "gh run view 123 --log-failed" "gh pr diff 45" \
         "ls -R /tmp" "ls -lR ." "tree src" "find . -name '*.js'" "find packages -type f"; do
  if quiet_rewrite "$c" >/dev/null; then pass "wrap: $c"; else bad "should wrap: $c"; fi
done
for c in "gh pr list" "gh run view 123" "gh pr diff 45 | head" "gh run view 1 --log > out.txt" \
         "gh run view 1 --logout" "ls -la" "ls" "find --help" "grep -r x ." "rg foo" \
         "find . -exec chmod 644 {} +" "yarn workspaces tree"; do
  if quiet_rewrite "$c" >/dev/null; then bad "should pass: $c"; else pass "pass: $c"; fi
done
# command-substitution must pass through (rewriting would corrupt the assignment)
quiet_rewrite 'files=$(find src -name x)' >/dev/null && bad "cmd-subst find should pass through" || pass "cmd-subst find passes through"
quiet_rewrite 'd=$(gh pr diff 1)' >/dev/null && bad "cmd-subst gh should pass through" || pass "cmd-subst gh passes through"

echo "== core: curl layer =="
for c in "curl https://api.example.com/data" "curl -s https://x/api" "curl -X POST https://x -d @body" \
         "/usr/bin/curl https://x"; do
  if quiet_rewrite "$c" >/dev/null; then pass "wrap: $c"; else bad "should wrap: $c"; fi
done
for c in "curl https://x | jq ." "curl -o out.json https://x" "curl -O https://x" "curl -I https://x" \
         "curl --head https://x" "curl https://x > out.json" "echo curl" "which curl" "man curl"; do
  if quiet_rewrite "$c" >/dev/null; then bad "should pass: $c"; else pass "pass: $c"; fi
done
quiet_rewrite 'd=$(curl https://x)' >/dev/null && bad "cmd-subst curl should pass through" || pass "cmd-subst curl passes through"

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

echo "== tool-result optimization (Claude Code PostToolUse) =="
MCP="$ROOT/adapters/claude-code-result.sh"
# Big payloads are fed to jq via --rawfile, not --arg: Linux caps a single argv
# entry at 128KB (MAX_ARG_STRLEN), so passing ~200KB strings on the CLI fails
# with "Argument list too long" on the CI runner (macOS has no per-arg cap).
MT=$(mktemp -d)
# large JSON result → replaced with a collapsed summary
bigjson=$(jq -nc '{items:[range(3000)|{id:.,name:"pkg",version:"1.0.0",url:"https://example.com/x"}]}')
printf '%s' "$bigjson" > "$MT/bigjson"
pj=$(jq -n --rawfile t "$MT/bigjson" '{tool_name:"mcp__search__query", tool_response:{content:[{type:"text",text:$t}]}}')
oj=$(printf '%s' "$pj" | "$MCP")
rep=$(printf '%s' "$oj" | jq -r '.hookSpecificOutput.updatedToolOutput.content[0].text' 2>/dev/null)
[ -n "$rep" ] && echo "$rep" | grep -q 'quiet-bash' && pass "large JSON MCP result replaced" || bad "mcp json replace"
[ "${#rep}" -lt "${#bigjson}" ] && pass "mcp summary smaller than raw (${#rep} < ${#bigjson})" || bad "mcp json not smaller"
echo "$rep" | grep -q 'more of 3000' && pass "mcp json collapses repeated shape" || bad "mcp json collapse"
# large TEXT result → spilled with head/tail
bigtext=$(for i in $(seq 1 4000); do echo "log line $i: something happened here with detail"; done)
printf '%s' "$bigtext" > "$MT/bigtext"
pt=$(jq -n --rawfile t "$MT/bigtext" '{tool_name:"mcp__web__fetch", tool_response:{content:[{type:"text",text:$t}]}}')
ot=$(printf '%s' "$pt" | "$MCP" | jq -r '.hookSpecificOutput.updatedToolOutput.content[0].text' 2>/dev/null)
echo "$ot" | grep -q 'spilled to' && echo "$ot" | grep -q 'first 20 lines' && pass "large text MCP result spilled + head/tail" || bad "mcp text spill"
# small result → pass through (no output)
ps=$(jq -n '{tool_name:"mcp__x__y", tool_response:{content:[{type:"text",text:"tiny result"}]}}')
[ -z "$(printf '%s' "$ps" | "$MCP")" ] && pass "small MCP result passes through" || bad "mcp small passthrough"
# already-wrapped → no double wrap
printf '[quiet-mcp] already done %s' "$bigtext" > "$MT/wrapped"
pw=$(jq -n --rawfile t "$MT/wrapped" '{tool_name:"mcp__x__y", tool_response:{content:[{type:"text",text:$t}]}}')
[ -z "$(printf '%s' "$pw" | "$MCP")" ] && pass "no double-wrap of quiet-mcp output" || bad "mcp double-wrap guard"
# non-text content (image) → pass through
pi=$(jq -n '{tool_name:"mcp__x__y", tool_response:{content:[{type:"image",data:"AAAA"}]}}')
[ -z "$(printf '%s' "$pi" | "$MCP")" ] && pass "non-text MCP content passes through" || bad "mcp non-text passthrough"
# NON-MCP tool with a STRING result (e.g. WebFetch) → replaced, mirroring string shape
bigstr=$(for i in $(seq 1 4000); do echo "fetched paragraph $i with a fair amount of text in it"; done)
printf '%s' "$bigstr" > "$MT/bigstr"
pstr=$(jq -n --rawfile t "$MT/bigstr" '{tool_name:"WebFetch", tool_response:$t}')
ostr=$(printf '%s' "$pstr" | "$MCP")
[ "$(printf '%s' "$ostr" | jq -r '.hookSpecificOutput.updatedToolOutput | type')" = "string" ] && pass "string result → string updatedToolOutput (shape mirrored)" || bad "string result shape"
printf '%s' "$ostr" | jq -r '.hookSpecificOutput.updatedToolOutput' | grep -q 'spilled to' && pass "WebFetch string result spilled" || bad "webfetch spill"
# unknown shape (object, no content[]) → pass through (safe no-op)
poth=$(jq -n --rawfile t "$MT/bigstr" '{tool_name:"Weird", tool_response:{weird:$t}}')
[ -z "$(printf '%s' "$poth" | "$MCP")" ] && pass "unknown result shape passes through" || bad "unknown shape passthrough"

echo "== result optimization: other agents =="
# Gemini AfterTool: result at .tool_response.llmContent → deny+reason
GR="$ROOT/adapters/gemini-result.sh"
pg=$(jq -n --rawfile t "$MT/bigjson" '{tool_name:"mcp_search_query", tool_response:{llmContent:$t}}')
og=$(printf '%s' "$pg" | "$GR")
{ [ "$(printf '%s' "$og" | jq -r '.decision')" = "deny" ] && printf '%s' "$og" | jq -r '.reason' | grep -q 'quiet-bash'; } && pass "gemini result → deny+reason (collapsed)" || bad "gemini result"
[ -z "$(printf '%s' "$(jq -n '{tool_name:"x", tool_response:{llmContent:"tiny"}}')" | "$GR")" ] && pass "gemini small passes through" || bad "gemini small"
# Copilot postToolUse: result at .toolResult.textResultForLlm → modifiedResult
CR="$ROOT/adapters/copilot-result.sh"
pc=$(jq -n --rawfile t "$MT/bigjson" '{toolName:"mcp_search_query", toolResult:{resultType:"success", textResultForLlm:$t}}')
oc=$(printf '%s' "$pc" | "$CR")
{ [ "$(printf '%s' "$oc" | jq -r '.modifiedResult.resultType')" = "success" ] && printf '%s' "$oc" | jq -r '.modifiedResult.textResultForLlm' | grep -q 'quiet-bash'; } && pass "copilot result → modifiedResult success" || bad "copilot result"
[ -z "$(printf '%s' "$(jq -n '{toolName:"x", toolResult:{resultType:"success", textResultForLlm:"tiny"}}')" | "$CR")" ] && pass "copilot small passes through" || bad "copilot small"
rm -rf "$MT"

echo "== quiet-query (smart query / aggregation) =="
QQ="$ROOT/core/quiet-query.sh"
QT=$(mktemp -d); qf="$QT/d.json"
jq -n '{meta:{v:1}, items:[{id:1,status:"ok",price:10},{id:2,status:"ok",price:20},{id:3,status:"err",price:30}]}' > "$qf"
[ "$("$QQ" "$qf" count '.items')" = "3" ] && pass "query count" || bad "query count"
[ "$("$QQ" "$qf" get '.meta.v')" = "1" ] && pass "query get" || bad "query get"
[ "$("$QQ" "$qf" group '.items' '.status' | jq -r '.ok')" = "2" ] && pass "query group (aggregate)" || bad "query group"
[ "$("$QQ" "$qf" stats '.items' '.price' | jq -r '.avg')" = "20" ] && pass "query stats avg" || bad "query stats"
[ "$("$QQ" "$qf" select '.items' '.price>15' | jq 'length')" = "2" ] && pass "query select (filter)" || bad "query select"
[ "$("$QQ" "$qf" pluck '.items' '.id' | jq -c .)" = "[1,2,3]" ] && pass "query pluck (project)" || bad "query pluck"
"$QQ" "$qf" keys | grep -q 'items: array' && pass "query keys" || bad "query keys"
"$QQ" "$qf" search 'err' | grep -q 'status' && pass "query search" || bad "query search"
# works on YAML too (via shared converter), if available
if command -v ruby >/dev/null 2>&1 || command -v yq >/dev/null 2>&1 || { command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; }; then
  printf 'items:\n  - {id: 1}\n  - {id: 2}\n' > "$QT/d.yaml"
  [ "$("$QQ" "$QT/d.yaml" count '.items')" = "2" ] && pass "query on YAML" || bad "query yaml"
fi
rm -rf "$QT"

echo "== MCP proxy (universal, any client) =="
if command -v node >/dev/null 2>&1; then
  node --check "$ROOT/proxy/quiet-mcp-proxy.mjs" && pass "proxy parses (node --check)" || bad "proxy syntax"
  PT=$(mktemp -d)
cat > "$PT/up.mjs" <<'JS'
import { createInterface } from 'node:readline'
createInterface({ input: process.stdin }).on('line', (line) => {
  let m; try { m = JSON.parse(line) } catch { return }
  if (m.method === 'tools/call') {
    const big = JSON.stringify({ items: Array.from({length:3000}, (_,i)=>({id:i,name:'pkg'})) })
    process.stdout.write(JSON.stringify({ jsonrpc:'2.0', id:m.id, result:{ content:[{ type:'text', text:big }] } }) + '\n', () => process.exit(0))
  }
})
JS
cat > "$PT/up_small.mjs" <<'JS'
import { createInterface } from 'node:readline'
createInterface({ input: process.stdin }).on('line', (line) => {
  let m; try { m = JSON.parse(line) } catch { return }
  if (m.method === 'tools/call') process.stdout.write(JSON.stringify({ jsonrpc:'2.0', id:m.id, result:{ content:[{ type:'text', text:'tiny' }] } }) + '\n', () => process.exit(0))
})
JS
  req='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"q"}}'
  pout=$(printf '%s\n' "$req" | node "$ROOT/proxy/quiet-mcp-proxy.mjs" node "$PT/up.mjs")
  { printf '%s' "$pout" | jq -r '.result.content[0].text' | grep -q 'quiet-bash' && [ "$(printf '%s' "$pout" | wc -c)" -lt 6000 ]; } && pass "proxy collapses large tools/call result" || bad "proxy collapse"
  pout2=$(printf '%s\n' "$req" | node "$ROOT/proxy/quiet-mcp-proxy.mjs" node "$PT/up_small.mjs")
  [ "$(printf '%s' "$pout2" | jq -r '.result.content[0].text')" = "tiny" ] && pass "proxy passes small result through unchanged" || bad "proxy small passthrough"
  rm -rf "$PT"
else
  echo "  (skipped — node not available)"
fi

echo "== source-file outlining =="
QO="$ROOT/core/quiet-outline.sh"
OT=$(mktemp -d)
# A large (>30KB) Python file with many symbols.
{
  echo "import os"
  echo "import sys"
  echo "from typing import List"
  for i in $(seq 1 400); do
    echo ""
    echo "def func_${i}(a, b):"
    echo "    # padding to grow the file well past the byte threshold xxxxxxxxxxxxxxxxxxxx"
    echo "    return a + b + ${i}"
  done
  echo ""
  echo "class Widget:"
  echo "    def render(self):"
  echo "        return 'MARKER_RENDER_BODY'"
} > "$OT/big.py"
po=$(QUIET_OUTLINE_MIN_BYTES=30000 "$QO" "$OT/big.py")
printf '%s' "$po" | grep -q '^\[quiet-bash\].*Python.*outline' && pass "python file outlined" || bad "python outline header"
printf '%s' "$po" | grep -q 'def func_1(a, b)' && pass "python signature shown" || bad "python signature"
printf '%s' "$po" | grep -qE 'body [0-9]+-[0-9]+' && pass "python body ranges shown" || bad "python body range"
# Range correctness: the Widget.render body range must contain the marker.
rng=$(printf '%s\n' "$po" | sed -n 's/.*render.*body \([0-9]*\)-\([0-9]*\)$/\1 \2/p' | head -1)
set -- $rng
[ -n "${1:-}" ] && sed -n "${1:-1},${2:-1}p" "$OT/big.py" | grep -q 'MARKER_RENDER_BODY' \
  && pass "python range expands to the real body" || bad "python range correctness"
# Byte threshold: small file (<30KB) with many symbols should NOT outline
{ echo "def a(): pass"; echo "def b(): pass"; echo "def c(): pass"; echo "def d(): pass"; } > "$OT/smallmany.py"
ps=$(QUIET_OUTLINE_MIN_BYTES=30000 "$QO" "$OT/smallmany.py")
printf '%s' "$ps" | grep -q '^\[quiet-bash\]' && bad "small file with many symbols should NOT outline" || pass "byte threshold: small file passes through raw"
# Symbol floor: a source-extension file with <3 symbols falls back to raw cat.
{ echo "x = 1"; for i in $(seq 1 4000); do echo "# comment line $i padding padding padding"; done; } > "$OT/data.py"
pf=$(QUIET_OUTLINE_MIN_BYTES=30000 "$QO" "$OT/data.py")
printf '%s' "$pf" | grep -q '^\[quiet-bash\]' && bad "symbol-floor should NOT outline" || pass "symbol-floor falls back to raw"
# Non-source extension → raw passthrough.
{ for i in $(seq 1 4000); do echo "plain text line $i"; done; } > "$OT/notes.txt"
pn=$("$QO" "$OT/notes.txt")
printf '%s' "$pn" | grep -q '^\[quiet-bash\]' && bad ".txt should not be outlined" || pass "non-source extension passthrough"
# TypeScript
{ echo "import x from 'y'"; for i in $(seq 1 300); do echo "export function fn${i}(a: number): number { return a + ${i} }"; echo "// padding to grow file past threshold xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; done; echo "export class Svc { run(): void { return } }"; } > "$OT/big.ts"
pt=$(QUIET_OUTLINE_MIN_BYTES=30000 "$QO" "$OT/big.ts"); printf '%s' "$pt" | grep -q '^\[quiet-bash\].*JS/TS.*outline' && printf '%s' "$pt" | grep -q 'export function fn1' && pass "ts outlined" || bad "ts outline"
# Go
{ echo "package main"; echo "import \"fmt\""; for i in $(seq 1 400); do echo "func Fn${i}() int { return ${i} }"; echo "// padding to grow file past threshold xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; done; echo "type T struct { x int }"; } > "$OT/big.go"
pg=$(QUIET_OUTLINE_MIN_BYTES=30000 "$QO" "$OT/big.go"); printf '%s' "$pg" | grep -q '^\[quiet-bash\].*Go.*outline' && printf '%s' "$pg" | grep -q 'func Fn1' && pass "go outlined" || bad "go outline"
# Rust
{ echo "use std::io;"; for i in $(seq 1 400); do echo "pub fn fn${i}() -> i32 { ${i} }"; echo "// padding to grow file past threshold xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; done; echo "struct S { x: i32 }"; } > "$OT/big.rs"
pr=$(QUIET_OUTLINE_MIN_BYTES=30000 "$QO" "$OT/big.rs"); printf '%s' "$pr" | grep -q '^\[quiet-bash\].*Rust.*outline' && printf '%s' "$pr" | grep -q 'fn fn1' && pass "rust outlined" || bad "rust outline"
# Java
{ echo "package a;"; echo "public class C {"; for i in $(seq 1 400); do echo "  public int m${i}() { return ${i}; }"; echo "  // padding to grow file past threshold xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; done; echo "}"; } > "$OT/big.java"
pj=$(QUIET_OUTLINE_MIN_BYTES=30000 "$QO" "$OT/big.java"); printf '%s' "$pj" | grep -q '^\[quiet-bash\].*Java.*outline' && printf '%s' "$pj" | grep -q 'class C' && pass "java outlined" || bad "java outline"
# Ruby
{ echo "require 'set'"; echo "class C"; for i in $(seq 1 400); do echo "  def m${i}; ${i}; end"; echo "  # padding to grow file past threshold xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; done; echo "end"; } > "$OT/big.rb"
pb=$(QUIET_OUTLINE_MIN_BYTES=30000 "$QO" "$OT/big.rb"); printf '%s' "$pb" | grep -q '^\[quiet-bash\].*Ruby.*outline' && printf '%s' "$pb" | grep -q 'def m1' && pass "ruby outlined" || bad "ruby outline"
# C
{ echo "#include <stdio.h>"; for i in $(seq 1 400); do echo "int fn${i}(int a) { return a + ${i}; }"; echo "// padding to grow file past threshold xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; done; echo "struct S { int x; };"; } > "$OT/big.c"
pc=$(QUIET_OUTLINE_MIN_BYTES=30000 "$QO" "$OT/big.c"); printf '%s' "$pc" | grep -q '^\[quiet-bash\].*C/C++.*outline' && printf '%s' "$pc" | grep -q 'fn1(' && pass "c outlined" || bad "c outline"
# Kotlin
{ echo "package a"; for i in $(seq 1 400); do echo "fun m${i}(x: Int): Int { return x + ${i} }"; done; echo "class C { fun run() {} }"; } > "$OT/big.kt"
pk=$(QUIET_OUTLINE_MIN_BYTES=30000 "$QO" "$OT/big.kt"); printf '%s' "$pk" | grep -q 'fun m1' && pass "kotlin outlined" || bad "kotlin outline"
# Scala
{ echo "package a"; echo "object O {"; for i in $(seq 1 400); do echo "  def m${i}(x: Int): Int = x + ${i}"; done; echo "}"; } > "$OT/big.scala"
psc=$(QUIET_OUTLINE_MIN_BYTES=30000 "$QO" "$OT/big.scala"); printf '%s' "$psc" | grep -q 'def m1' && pass "scala outlined" || bad "scala outline"
# PHP
{ echo "<?php"; echo "class C {"; for i in $(seq 1 400); do echo "  function m${i}() { return ${i}; }"; done; echo "}"; } > "$OT/big.php"
pp=$(QUIET_OUTLINE_MIN_BYTES=30000 "$QO" "$OT/big.php"); printf '%s' "$pp" | grep -q 'function m1' && pass "php outlined" || bad "php outline"
# Swift
{ echo "import Foundation"; for i in $(seq 1 400); do echo "func m${i}(x: Int) -> Int { return x + ${i} }"; done; echo "struct S { func run() {} }"; } > "$OT/big.swift"
pw=$(QUIET_OUTLINE_MIN_BYTES=30000 "$QO" "$OT/big.swift"); printf '%s' "$pw" | grep -q 'func m1' && pass "swift outlined" || bad "swift outline"
# quiet_rewrite routes a large source read to the outliner
qr=$(quiet_rewrite "cat $OT/big.py") && printf '%s' "$qr" | grep -q 'quiet-outline.sh' && pass "rewrite routes big.py to outliner" || bad "rewrite big.py"
# piped read is left alone
quiet_rewrite "cat $OT/big.py | grep def" >/dev/null && bad "piped read should pass through" || pass "piped source read passes through"
# small source file is left alone
echo "def tiny(): pass" > "$OT/tiny.py"
quiet_rewrite "cat $OT/tiny.py" >/dev/null && bad "small file should pass through" || pass "small source read passes through"
# Native Read path: tool_input.path to a large source file → outline in updatedToolOutput
CR="$ROOT/adapters/claude-code-result.sh"
content=$(cat "$OT/big.py")
payload=$(jq -n --arg p "$OT/big.py" --arg c "$content" '{tool_name:"Read", tool_input:{path:$p}, tool_response:$c}')
ro=$(printf '%s' "$payload" | QUIET_OUTLINE_MIN_BYTES=30000 "$CR")
printf '%s' "$ro" | jq -r '.hookSpecificOutput.updatedToolOutput' 2>/dev/null | grep -q 'outline' \
  && pass "native Read of big.py is outlined" || bad "native Read outline"
# Edit of a large .py returns a small success message → must pass through, NOT be outlined
epayload=$(jq -n --arg p "$OT/big.py" '{tool_name:"Edit", tool_input:{file_path:$p}, tool_response:"The file has been updated successfully."}')
eo=$(printf '%s' "$epayload" | QUIET_OUTLINE_MIN_BYTES=30000 "$CR")
# small result → adapter exits 0 (no output) OR passes the message through; either way it must NOT contain an outline
printf '%s' "$eo" | grep -q 'outline' && bad "Edit result must not be outlined" || pass "Edit result not clobbered by outline"
# Grep over a large .py returning a small match → must NOT be outlined
gpayload=$(jq -n --arg p "$OT/big.py" '{tool_name:"Grep", tool_input:{path:$p}, tool_response:"big.py:12: def func_12(a, b):"}')
go=$(printf '%s' "$gpayload" | QUIET_OUTLINE_MIN_BYTES=30000 "$CR")
printf '%s' "$go" | grep -q 'outline' && bad "Grep result must not be outlined" || pass "Grep result not clobbered by outline"
# Large NON-source Read (e.g. a .txt) → must pass through untouched (no head/tail, no rewrite)
{ for i in $(seq 1 4000); do echo "log line $i ................................................"; done; } > "$OT/big.txt"
tpayload=$(jq -n --arg p "$OT/big.txt" --arg c "$(cat "$OT/big.txt")" '{tool_name:"Read", tool_input:{path:$p}, tool_response:$c}')
to=$(printf '%s' "$tpayload" | QUIET_OUTLINE_MIN_BYTES=30000 "$CR")
[ -z "$to" ] && pass "large non-source Read passes through untouched" || bad "non-source Read should pass through"
# Wiring regression: the PostToolUse matcher MUST include Read (else native-Read outlining never fires)
HJ="$ROOT/hooks/hooks.json"
jq -e '.hooks.PostToolUse[]?.matcher | select(test("(^|\\|)Read($|\\|)"))' "$HJ" >/dev/null 2>&1 \
  && pass "hooks.json PostToolUse matcher includes Read" || bad "PostToolUse matcher missing Read"
rm -rf "$OT"

echo "== quiet_rewrite edge cases (builtin-regex conversion) =="
ED=$(mktemp -d)
python3 -c "import json,sys; open(sys.argv[1],'w').write(json.dumps({'a':list(range(8000))}))" "$ED/big.json" 2>/dev/null \
  || { printf '{"a":['; for i in $(seq 1 8000); do printf '%d,' "$i"; done; printf '0]}'; } > "$ED/big.json"
quiet_rewrite "git diff | head" >/dev/null && bad "piped git should pass through" || pass "piped git passes through ([|] literal)"
quiet_rewrite "git diff --stat" >/dev/null && bad "git --stat should pass through" || pass "git --stat passes through"
quiet_rewrite "git diff" >/dev/null && pass "git diff still wraps" || bad "git diff should wrap"
{ quiet_rewrite "jq . $ED/big.json" | grep -q quiet-json.sh; } && pass "jq . big.json routes to quiet-json" || bad "jq . routing"
{ quiet_rewrite "cat $ED/big.json" | grep -q quiet-json.sh; } && pass "cat big.json routes to quiet-json" || bad "cat json routing"
rm -rf "$ED"

echo "== quiet-tail (ANSI strip / progress collapse / dup fold) =="
QT="$ROOT/core/quiet-tail.sh"
TT=$(mktemp -d); lf="$TT/log"
printf 'starting build\n\033[31mERROR:\033[0m boom\nDownloading [..  ]\rDownloading [....]\rDownloading [done]\nsame line\nsame line\nsame line\ntail end\n' > "$lf"
before=$(wc -c <"$lf" | tr -d ' ')
out=$("$QT" "$lf" 40)
printf '%s' "$out" | grep -q '\033' && bad "quiet-tail leaves ANSI codes" || pass "quiet-tail strips ANSI"
printf '%s' "$out" | grep -q 'ERROR: boom' && pass "quiet-tail keeps error text" || bad "quiet-tail dropped error text"
printf '%s' "$out" | grep -q 'Downloading \[done\]' && ! printf '%s' "$out" | grep -q 'Downloading \[\.\.' \
  && pass "quiet-tail collapses \\r progress to final state" || bad "quiet-tail progress collapse"
printf '%s' "$out" | grep -qE 'same line  \(x3\)' && pass "quiet-tail folds consecutive duplicates" || bad "quiet-tail dup fold"
# the log on disk must be untouched (byte-exact before vs after)
[ "$(wc -c <"$lf" | tr -d ' ')" = "$before" ] && pass "quiet-tail leaves the log file untouched" || bad "quiet-tail modified the log"
# missing file → empty, no crash
[ -z "$("$QT" "$TT/nope" 40)" ] && pass "quiet-tail missing file → empty" || bad "quiet-tail missing file"
rm -rf "$TT"

echo "== minimal-change skill =="
MC="$ROOT/skills/minimal-change/SKILL.md"
[ -f "$MC" ] && pass "minimal-change SKILL.md exists" || bad "minimal-change missing"
head -1 "$MC" | grep -q '^---$' && pass "minimal-change frontmatter fence" || bad "minimal-change fence"
grep -q '^name: minimal-change$' "$MC" && pass "minimal-change has name" || bad "minimal-change name"
grep -qE '^description: .+' "$MC" && pass "minimal-change has description" || bad "minimal-change description"
grep -qi 'no-regression floor' "$MC" && pass "minimal-change has no-regression floor" || bad "minimal-change floor"
{ grep -qi 'inspired by' "$MC" && grep -qi 'ponytail' "$MC"; } && pass "minimal-change credits ponytail" || bad "minimal-change attribution"

echo "== minimal-docs skill =="
MD="$ROOT/skills/minimal-docs/SKILL.md"
[ -f "$MD" ] && pass "minimal-docs SKILL.md exists" || bad "minimal-docs missing"
head -1 "$MD" | grep -q '^---$' && pass "minimal-docs frontmatter fence" || bad "minimal-docs fence"
grep -q '^name: minimal-docs$' "$MD" && pass "minimal-docs has name" || bad "minimal-docs name"
grep -qE '^description: .+' "$MD" && pass "minimal-docs has description" || bad "minimal-docs description"
grep -qi 'no-regression floor' "$MD" && pass "minimal-docs has no-regression floor" || bad "minimal-docs floor"
{ grep -qi 'inspired by' "$MD" && grep -qi 'ponytail' "$MD"; } && pass "minimal-docs credits ponytail" || bad "minimal-docs attribution"

echo "== concise output style =="
OS="$ROOT/output-styles/concise.md"
[ -f "$OS" ] && pass "concise output-style exists" || bad "output-style missing"
head -1 "$OS" | grep -q '^---$' && pass "output-style has frontmatter fence" || bad "output-style frontmatter fence"
grep -q '^name: Concise$' "$OS" && pass "output-style has name" || bad "output-style name"
grep -qE '^description: .+' "$OS" && pass "output-style has description" || bad "output-style description"
grep -q '^keep-coding-instructions: true$' "$OS" && pass "output-style keeps coding instructions" || bad "output-style keep-coding-instructions"
grep -qi "don't drop substantive content" "$OS" && pass "output-style guards against detail loss" || bad "output-style no-loss guardrail"

echo "== quiet_prune throttle =="
PD=$(mktemp -d)
( QUIET_LOG_DIR="$PD"; quiet_prune; [ -f "$PD/${QUIET_LOG_PREFIX}prune-stamp" ]; ) \
  && pass "quiet_prune writes a throttle stamp" || bad "quiet_prune stamp missing"
( QUIET_LOG_DIR="$PD"; quiet_prune ) && pass "quiet_prune second call ok (throttled)" || bad "quiet_prune second call"
rm -rf "$PD"

echo "== opencode plugin (tool.execute.after) =="
if command -v node >/dev/null 2>&1; then
  oct=$(QB_ROOT="$ROOT" node --input-type=module -e '
    const plugin = (await import(process.env.QB_ROOT + "/adapters/opencode.mjs")).default;
    const h = await plugin();
    const big = "line\n".repeat(20000), small = "ok\n";
    const r1 = { output: big, metadata: {} };   await h["tool.execute.after"]({ tool: "bash" }, r1);
    const r2 = { output: small, metadata: {} };  await h["tool.execute.after"]({ tool: "bash" }, r2);
    const r3 = { output: big, metadata: {} };    await h["tool.execute.after"]({ tool: "read" }, r3);
    process.stdout.write((r1.output.startsWith("[quiet-bash]")?"Q":"q") + (r2.output===small?"P":"p") + (r3.output===big?"P":"p"));
  ' 2>/dev/null)
  [ "$oct" = "QPP" ] && pass "opencode plugin: quiets large bash, passes small + non-bash" || bad "opencode plugin behavior ($oct)"
else
  echo "  (skipped — node not available)"
fi

echo "== quiet-prompt (split: inline rules, spill [ref] reference) =="
QPD=$(mktemp -d); pf="$QPD/p.md"
{ echo "# A"; echo "## Rules"; echo "MANDATORY token X."; \
  echo "## Big [ref]"; for i in $(seq 1 300); do echo "ref line $i padding padding padding"; done; } > "$pf"
QP="$ROOT/core/quiet-prompt.sh"
stub=$("$QP" "$pf")
echo "$stub" | grep -q "MANDATORY token X." && pass "quiet-prompt keeps untagged rules inline" || bad "quiet-prompt dropped inline rules"
{ ! echo "$stub" | grep -q "ref line 150"; } && pass "quiet-prompt spills [ref] body" || bad "quiet-prompt left [ref] body inline"
echo "$stub" | grep -q "load a section when the task needs it" && pass "quiet-prompt emits load-on-demand pointer" || bad "quiet-prompt missing pointer"
[ "$(printf '%s' "$stub" | wc -c)" -lt "$(wc -c <"$pf")" ] && pass "quiet-prompt stub smaller than prompt" || bad "quiet-prompt stub not smaller"
"$QP" "$pf" --section "Big" | grep -q "ref line 1 " && pass "quiet-prompt --section loads spilled section" || bad "quiet-prompt --section failed"
# safety: no [ref] tags -> pass through whole, no quieting
nf="$QPD/n.md"; { echo "# N"; echo "## Rules"; for i in $(seq 1 300); do echo "rule line $i padding padding padding"; done; } > "$nf"
[ "$("$QP" "$nf" | grep -c 'rule line')" -eq 300 ] && pass "quiet-prompt passes through when nothing tagged [ref]" || bad "quiet-prompt quieted untagged prompt"
rm -rf "$QPD"

echo "== quiet-verify =="
QV="$ROOT/core/quiet-verify.sh"
VF=$(mktemp); printf 'build ok\nPASS test_a\nPASS test_b\n' > "$VF"
out=$("$QV" "$VF" 'PASS'); st=$?
{ [ "$st" -eq 0 ] && printf '%s' "$out" | grep -q 'OK' && printf '%s' "$out" | grep -q '2 line'; } \
  && pass "quiet-verify hit: OK + count + exit 0" || bad "quiet-verify hit"
out=$("$QV" "$VF" 'FAILURE'); st=$?
{ [ "$st" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL'; } \
  && pass "quiet-verify miss: FAIL + exit 1" || bad "quiet-verify miss"
"$QV" "$VF" >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-verify usage exit 2" || bad "quiet-verify usage"
"$QV" /no/such/file 'x' >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-verify missing-file exit 2" || bad "quiet-verify missing-file"
"$QV" "$VF" '[' >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-verify invalid regex exit 2" || bad "quiet-verify invalid regex exit 2"
rm -f "$VF"

echo "== quiet-agg =="
QA="$ROOT/core/quiet-agg.sh"
AF=$(mktemp); printf 'E101 boom\nE200 nope\nE101 again\nE101 third\nE200 second\n' > "$AF"
out=$("$QA" "$AF" 'E[0-9]+')
# E101 appears 3×, E200 2× — E101 must be the first data row
top=$(printf '%s' "$out" | grep -E 'E[0-9]+' | grep -v '\[quiet-agg\]' | head -1)
{ printf '%s' "$top" | grep -q 'E101' && printf '%s' "$top" | grep -q '3'; } \
  && pass "quiet-agg ranks E101(3) first" || bad "quiet-agg ranking"
out=$("$QA" "$AF" 'ZZZ'); st=$?
{ [ "$st" -eq 0 ] && printf '%s' "$out" | grep -q 'no matches'; } \
  && pass "quiet-agg no-match exit 0" || bad "quiet-agg no-match"
"$QA" "$AF" >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-agg usage exit 2" || bad "quiet-agg usage"
"$QA" "$AF" 'E[0-9]+' 0 >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-agg n=0 exit 2" || bad "quiet-agg n=0 exit 2"
"$QA" "$AF" 'E[0-9]+' abc >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-agg n=abc exit 2" || bad "quiet-agg n=abc exit 2"
"$QA" "$AF" '[' >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-agg invalid regex exit 2" || bad "quiet-agg invalid regex exit 2"
rm -f "$AF"

echo "== deterministic-first skill =="
SK="$ROOT/skills/deterministic-first/SKILL.md"
[ -f "$SK" ] && pass "skill file exists" || bad "skill file exists"
grep -q '^name: deterministic-first' "$SK" 2>/dev/null && pass "skill name frontmatter" || bad "skill name"
grep -q '^description: Use before' "$SK" 2>/dev/null && pass "skill description trigger" || bad "skill description"
for h in 'The decision rule' 'Compose with quiet-bash' 'The no-regression floor'; do
  grep -qF "$h" "$SK" 2>/dev/null && pass "skill section: $h" || bad "skill section: $h"
done
grep -q 'quiet-agg' "$SK" 2>/dev/null && grep -q 'quiet-verify' "$SK" 2>/dev/null \
  && pass "skill references the verbs" || bad "skill references verbs"

echo "== composition: spill -> recover with a verb =="
. "$ROOT/core/quiet-core.sh"
# Run a command whose output quiet_run spills to a temp log, then recover the
# answer from that spill with a verb — without re-reading the haystack.
SPILL_MSG=$(quiet_run printf 'WARN a\nERROR boom\nWARN b\n')
LOG=$(printf '%s' "$SPILL_MSG" | grep -oE "${QUIET_LOG_DIR%/}/+${QUIET_LOG_PREFIX}[A-Za-z0-9]+" | head -1)
{ [ -n "$LOG" ] && [ -f "$LOG" ]; } && pass "spill log created" || bad "spill log created"
"$ROOT/core/quiet-verify.sh" "$LOG" 'ERROR' >/dev/null && pass "recover: verify hit on spill" || bad "recover: verify"
"$ROOT/core/quiet-agg.sh" "$LOG" 'WARN|ERROR' | grep -q 'WARN' && pass "recover: agg on spill" || bad "recover: agg"

echo "== model-economy: grading =="
. "$ROOT/bench/model-economy-tasks.sh"
# task 0 asserts the answer mentions the known symbol; grade pass/fail on canned answers
if [ "$(me_grade 0 'The function is exported as quiet_rewrite in quiet-core.sh')" = pass ]; then
  pass "grade: correct answer for task0 → pass"
else bad "grade: correct answer for task0 should pass"; fi
if [ "$(me_grade 0 'I could not find anything relevant')" = fail ]; then
  pass "grade: wrong answer for task0 → fail"
else bad "grade: wrong answer for task0 should fail"; fi
if [ "$(me_grade 99 'anything at all')" = fail ]; then
  pass "grade: out-of-range index → fail (no silent pass)"
else bad "grade: out-of-range index must fail, not silently pass"; fi
# every task must have an index-aligned assertion
if [ "${#ME_TASK_PROMPTS[@]}" -eq "${#ME_TASK_ASSERTS[@]}" ] && [ "${#ME_TASK_PROMPTS[@]}" -gt 0 ]; then
  pass "suite: prompts and asserts are aligned and non-empty"
else bad "suite: prompts/asserts misaligned or empty"; fi

echo "== model-economy: report =="
me_tmp="$(mktemp)"
cat > "$me_tmp" <<'JSONL'
{"arm":"baseline","task":0,"rep":1,"input":1000,"output":50,"cost":0.02,"ms":4000,"turns":3,"pass":true}
{"arm":"baseline","task":1,"rep":1,"input":1200,"output":60,"cost":0.03,"ms":4200,"turns":3,"pass":true}
{"arm":"A","task":0,"rep":1,"input":1000,"output":50,"cost":0.01,"ms":3000,"turns":3,"pass":true}
{"arm":"A","task":1,"rep":1,"input":1200,"output":60,"cost":0.015,"ms":3100,"turns":3,"pass":true}
JSONL
me_rep="$(python3 "$ROOT/bench/model-economy-report.py" "$me_tmp")"
if printf '%s' "$me_rep" | grep -q "ZERO-REGRESSION ✓"; then
  pass "report: equal pass-rate → zero-regression ✓"
else bad "report: should report zero-regression when pass-rates match"; fi
if printf '%s' "$me_rep" | grep -Eq "cost -[0-9]"; then
  pass "report: cheaper A arm → negative cost delta"
else bad "report: should show negative cost delta for cheaper arm"; fi
if printf '%s' "$me_rep" | grep -Eq "arm A:.*→ SHIP"; then
  pass "report: zero-regression + cheaper → SHIP verdict"
else bad "report: cheaper zero-regression arm should yield SHIP"; fi
rm -f "$me_tmp"

echo
[ "$fail" -eq 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
