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

echo "== tool-result optimization (Claude Code PostToolUse) =="
MCP="$ROOT/adapters/claude-code-result.sh"
# large JSON result → replaced with a collapsed summary
bigjson=$(jq -nc '{items:[range(3000)|{id:.,name:"pkg",version:"1.0.0",url:"https://example.com/x"}]}')
pj=$(jq -n --arg t "$bigjson" '{tool_name:"mcp__search__query", tool_response:{content:[{type:"text",text:$t}]}}')
oj=$(printf '%s' "$pj" | "$MCP")
rep=$(printf '%s' "$oj" | jq -r '.hookSpecificOutput.updatedToolOutput.content[0].text' 2>/dev/null)
[ -n "$rep" ] && echo "$rep" | grep -q 'quiet-bash' && pass "large JSON MCP result replaced" || bad "mcp json replace"
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
# NON-MCP tool with a STRING result (e.g. WebFetch) → replaced, mirroring string shape
bigstr=$(for i in $(seq 1 4000); do echo "fetched paragraph $i with a fair amount of text in it"; done)
pstr=$(jq -n --arg t "$bigstr" '{tool_name:"WebFetch", tool_response:$t}')
ostr=$(printf '%s' "$pstr" | "$MCP")
[ "$(printf '%s' "$ostr" | jq -r '.hookSpecificOutput.updatedToolOutput | type')" = "string" ] && pass "string result → string updatedToolOutput (shape mirrored)" || bad "string result shape"
printf '%s' "$ostr" | jq -r '.hookSpecificOutput.updatedToolOutput' | grep -q 'spilled to' && pass "WebFetch string result spilled" || bad "webfetch spill"
# unknown shape (object, no content[]) → pass through (safe no-op)
poth=$(jq -n --arg t "$bigstr" '{tool_name:"Weird", tool_response:{weird:$t}}')
[ -z "$(printf '%s' "$poth" | "$MCP")" ] && pass "unknown result shape passes through" || bad "unknown shape passthrough"

echo "== result optimization: other agents =="
# Gemini AfterTool: result at .tool_response.llmContent → deny+reason
GR="$ROOT/adapters/gemini-result.sh"
pg=$(jq -n --arg t "$bigjson" '{tool_name:"mcp_search_query", tool_response:{llmContent:$t}}')
og=$(printf '%s' "$pg" | "$GR")
{ [ "$(printf '%s' "$og" | jq -r '.decision')" = "deny" ] && printf '%s' "$og" | jq -r '.reason' | grep -q 'quiet-bash'; } && pass "gemini result → deny+reason (collapsed)" || bad "gemini result"
[ -z "$(printf '%s' "$(jq -n '{tool_name:"x", tool_response:{llmContent:"tiny"}}')" | "$GR")" ] && pass "gemini small passes through" || bad "gemini small"
# Copilot postToolUse: result at .toolResult.textResultForLlm → modifiedResult
CR="$ROOT/adapters/copilot-result.sh"
pc=$(jq -n --arg t "$bigjson" '{toolName:"mcp_search_query", toolResult:{resultType:"success", textResultForLlm:$t}}')
oc=$(printf '%s' "$pc" | "$CR")
{ [ "$(printf '%s' "$oc" | jq -r '.modifiedResult.resultType')" = "success" ] && printf '%s' "$oc" | jq -r '.modifiedResult.textResultForLlm' | grep -q 'quiet-bash'; } && pass "copilot result → modifiedResult success" || bad "copilot result"
[ -z "$(printf '%s' "$(jq -n '{toolName:"x", toolResult:{resultType:"success", textResultForLlm:"tiny"}}')" | "$CR")" ] && pass "copilot small passes through" || bad "copilot small"

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

echo "== quiet_prune throttle =="
PD=$(mktemp -d)
( QUIET_LOG_DIR="$PD"; quiet_prune; [ -f "$PD/${QUIET_LOG_PREFIX}prune-stamp" ]; ) \
  && pass "quiet_prune writes a throttle stamp" || bad "quiet_prune stamp missing"
( QUIET_LOG_DIR="$PD"; quiet_prune ) && pass "quiet_prune second call ok (throttled)" || bad "quiet_prune second call"
rm -rf "$PD"

echo
[ "$fail" -eq 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
