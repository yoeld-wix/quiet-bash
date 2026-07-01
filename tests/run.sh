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
for c in "ls -la" "cat f.txt" "grep x f.txt" "git status" "gh pr list" "echo hi" "pwd" \
         "cd /tmp" "which node" "git diff --stat" "git log --oneline" "yarn info x"; do
  if quiet_rewrite "$c" >/dev/null; then bad "should pass: $c"; else pass "pass: $c"; fi
done

echo "== core: gh + recursive-listing layers =="
for c in "gh run view 123 --log" "gh run view 123 --log-failed" "gh pr diff 45" \
         "ls -R /tmp" "ls -lR ." "tree src" "find . -name '*.js'" "find packages -type f"; do
  if quiet_rewrite "$c" >/dev/null; then pass "wrap: $c"; else bad "should wrap: $c"; fi
done
for c in "gh pr list" "gh run view 123" "gh pr diff 45 | head" "gh run view 1 --log > out.txt" \
         "gh run view 1 --logout" "ls -la" "ls" "find --help" \
         "find . -exec chmod 644 {} +" "yarn workspaces tree"; do
  if quiet_rewrite "$c" >/dev/null; then bad "should pass: $c"; else pass "pass: $c"; fi
done
# command-substitution must pass through (rewriting would corrupt the assignment)
quiet_rewrite 'files=$(find src -name x)' >/dev/null && bad "cmd-subst find should pass through" || pass "cmd-subst find passes through"
quiet_rewrite 'd=$(gh pr diff 1)' >/dev/null && bad "cmd-subst gh should pass through" || pass "cmd-subst gh passes through"

echo "== core: infra/listing/logdump coverage =="
for c in "terraform plan" "terraform apply -auto-approve" "helm upgrade x ./chart" "pulumi up" \
         "ansible-playbook site.yml" "kubectl get pods -A" "kubectl describe pod x" "kubectl logs mypod" \
         "docker images" "docker ps -a" "docker logs web" "npm ls" "pnpm list" "pip list" "pip freeze" \
         "pip show requests" "brew list" "journalctl -u nginx"; do
  if quiet_rewrite "$c" >/dev/null; then pass "wrap: $c"; else bad "should wrap: $c"; fi
done
# must pass through: non-verbose subcommands, explicit limits, and assignment-corrupting forms
for c in "terraform version" "helm version" "kubectl version" "kubectl get pods | head" \
         "docker logs web > out.txt" "pip show requests | grep Version" "npm ls --help"; do
  if quiet_rewrite "$c" >/dev/null; then bad "should pass: $c"; else pass "pass: $c"; fi
done
quiet_rewrite 'pods=$(kubectl get pods)' >/dev/null && bad "cmd-subst kubectl should pass through" || pass "cmd-subst kubectl passes through"

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

echo "== core: recursive-search collapse (grep -r / rg) =="
for c in "grep -r x ." "grep -R foo src" "grep -rn TODO ." "rg foo" "rg bar src" "rg -n foo"; do
  if quiet_rewrite "$c" >/dev/null; then pass "wrap: $c"; else bad "should wrap: $c"; fi
done
for c in "grep x f.txt" "grep -rl x ." "grep -c x ." "rg -l foo" "rg -c foo" "rg foo | head" \
         "grep -r x . > out" "grep -r x . | wc -l" 'd=$(rg foo)'; do
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
# Big payloads are fed to jq via --rawfile, not --arg: Linux caps a single argv
# entry at 128KB (MAX_ARG_STRLEN), so passing ~200KB strings on the CLI fails
# with "Argument list too long" on the CI runner (macOS has no per-arg cap).
MT=$(mktemp -d)
# large JSON result → replaced with a collapsed summary
bigjson=$(jq -nc '{items:[range(3000)|{id:.,name:"pkg",version:"1.0.0",url:"https://example.com/x"}]}')
printf '%s' "$bigjson" > "$MT/bigjson"
# DEFAULT (opt-in OFF): result quieting is dormant — a large result passes through.
pj0=$(jq -n --rawfile t "$MT/bigjson" '{tool_name:"mcp__search__query", tool_response:{content:[{type:"text",text:$t}]}}')
[ -z "$(printf '%s' "$pj0" | env -u QUIET_RESULT_HOOK "$MCP")" ] \
  && pass "result quieting OFF by default (large result passes through)" || bad "result hook should be off by default"
# The rest of this section exercises the OPT-IN behaviour:
export QUIET_RESULT_HOOK=1
pj=$(jq -n --rawfile t "$MT/bigjson" '{tool_name:"mcp__search__query", tool_response:{content:[{type:"text",text:$t}]}}')
oj=$(printf '%s' "$pj" | "$MCP")
rep=$(printf '%s' "$oj" | jq -r '.hookSpecificOutput.updatedToolOutput.content[0].text' 2>/dev/null)
[ -n "$rep" ] && echo "$rep" | grep -q 'quiet-bash' && pass "large JSON MCP result replaced" || bad "mcp json replace"
[ "${#rep}" -lt "${#bigjson}" ] && pass "mcp summary smaller than raw (${#rep} < ${#bigjson})" || bad "mcp json not smaller"
echo "$rep" | grep -q 'more of 3000' && pass "mcp json collapses repeated shape" || bad "mcp json collapse"
# anti-thrash guarantee: a collapsed JSON result must stay LOSSLESS and queryable
# so the agent drills into the spill instead of re-fetching. (The 3-arm benchmark's
# apparent "full-arm regression" was turn-count variance, NOT this path — keep it
# that way structurally: lossy/non-queryable results are what would cause re-fetch.)
spillref=$(printf '%s' "$rep" | grep -oE '/[^ "]+result-[A-Za-z0-9]+\.json' | head -1)
{ [ -n "$spillref" ] && [ -f "$spillref" ] && cmp -s "$MT/bigjson" "$spillref"; } \
  && pass "mcp json spill is byte-exact (lossless — no re-fetch needed)" || bad "mcp json spill not byte-exact"
echo "$rep" | grep -q 'quiet-query.sh' && pass "mcp json summary points to quiet-query (drill-in, not re-fetch)" || bad "mcp json missing query pointer"
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
# Result-hook split: the LOSSY/expensive paths (source outlining, MCP collapse)
# are opt-in; the LOSSLESS dedup stays ON by default. Prove both with the var unset.
CR="$ROOT/adapters/claude-code-result.sh"
bigpy_payload=$(jq -n --arg p "$OT/big.py" --rawfile c "$OT/big.py" --arg s "sessSPLIT" \
  '{session_id:$s, tool_name:"Read", tool_input:{path:$p}, tool_response:$c}')
# (1) source outlining is OFF by default → first read passes through (no outline)
off1=$(printf '%s' "$bigpy_payload" | env -u QUIET_RESULT_HOOK QUIET_OUTLINE_MIN_BYTES=30000 "$CR")
printf '%s' "$off1" | jq -r '.hookSpecificOutput.updatedToolOutput' 2>/dev/null | grep -q 'outline' \
  && bad "source outlining must be off by default" || pass "source outlining off by default"
# (2) Read-dedup is ON by default → the second identical unchanged read is stubbed sans var
off2=$(printf '%s' "$bigpy_payload" | env -u QUIET_RESULT_HOOK QUIET_OUTLINE_MIN_BYTES=30000 "$CR")
printf '%s' "$off2" | grep -q 'unchanged since you read it' \
  && pass "Read-dedup stays ON by default (split)" || bad "Read-dedup should be on by default"

# Native Read path: tool_input.path to a large source file → outline in updatedToolOutput
# (opt-in path — outlining is off by default; see the PostToolUse section above)
export QUIET_RESULT_HOOK=1
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
tpayload=$(jq -n --arg p "$OT/big.txt" --rawfile c "$OT/big.txt" '{tool_name:"Read", tool_input:{path:$p}, tool_response:$c}')
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

echo "== quiet-check =="
QC="$ROOT/core/quiet-check.sh"
CF=$(mktemp); printf 'building...\nWARNING deprecated\nERROR boom\nFAILED step 2\nok done\n' > "$CF"
out=$("$QC" "$CF"); st=$?
{ [ "$st" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL' && printf '%s' "$out" | grep -qE '2 error' && printf '%s' "$out" | grep -qE '1 warning'; } \
  && pass "quiet-check FAIL + tally + exit 1" || bad "quiet-check fail-case"
printf '%s' "$out" | grep -q 'first 5 error' && pass "quiet-check shows first errors" || bad "quiet-check first errors"
GF=$(mktemp); printf 'building...\nall good\nok done\n' > "$GF"
out=$("$QC" "$GF"); st=$?
{ [ "$st" -eq 0 ] && printf '%s' "$out" | grep -q 'PASS' && printf '%s' "$out" | grep -qE '0 error'; } \
  && pass "quiet-check PASS + exit 0" || bad "quiet-check pass-case"
"$QC" >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-check usage exit 2" || bad "quiet-check usage"
"$QC" /no/such/file >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-check missing-file exit 2" || bad "quiet-check missing-file"
QUIET_CHECK_ERROR_RE='[' "$QC" "$CF" >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-check invalid regex exit 2" || bad "quiet-check invalid regex"
QUIET_CHECK_FIRST_K=abc "$QC" "$CF" >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-check non-numeric QUIET_CHECK_FIRST_K exit 2" || bad "quiet-check non-numeric QUIET_CHECK_FIRST_K"
rm -f "$CF" "$GF"

echo "== quiet-wait =="
QW="$ROOT/core/quiet-wait.sh"
out=$("$QW" 'true' --timeout 2 --interval 1); st=$?
{ [ "$st" -eq 0 ] && printf '%s' "$out" | grep -q 'condition met'; } && pass "quiet-wait success exit 0" || bad "quiet-wait success"
out=$("$QW" 'false' --timeout 1 --interval 1); st=$?
{ [ "$st" -eq 1 ] && printf '%s' "$out" | grep -q 'TIMEOUT'; } && pass "quiet-wait timeout exit 1" || bad "quiet-wait timeout"
"$QW" >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-wait usage exit 2" || bad "quiet-wait usage"
"$QW" 'true' --timeout abc >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-wait bad timeout exit 2" || bad "quiet-wait bad timeout"

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

echo "== quiet-dedup =="
( # subshell so QUIET_LOG_DIR override is local
  export QUIET_LOG_DIR; QUIET_LOG_DIR=$(mktemp -d)
  . "$ROOT/core/quiet-dedup.sh"
  DF="$QUIET_LOG_DIR/data.txt"; printf 'hello\nworld\n' > "$DF"
  # first read: pass through (no output), returns 1
  o1=$(quiet_dedup_check "sessA" "$DF" "" ""); r1=$?
  { [ "$r1" -eq 1 ] && [ -z "$o1" ]; } && pass "dedup first read passes through" || bad "dedup first read"
  # second identical read: dedup (output + returns 0)
  o2=$(quiet_dedup_check "sessA" "$DF" "" ""); r2=$?
  { [ "$r2" -eq 0 ] && printf '%s' "$o2" | grep -q 'unchanged since you read it'; } && pass "dedup repeat read deduped" || bad "dedup repeat read"
  # changed mtime+content: pass through
  sleep 1; printf 'hello\nworld\nmore\n' > "$DF"
  o3=$(quiet_dedup_check "sessA" "$DF" "" ""); r3=$?
  [ "$r3" -eq 1 ] && pass "dedup changed file passes through" || bad "dedup changed file"
  # different range: different key → pass through
  o4=$(quiet_dedup_check "sessA" "$DF" "10" "20"); r4=$?
  [ "$r4" -eq 1 ] && pass "dedup different range passes through" || bad "dedup different range"
  # no session id: disabled
  o5=$(quiet_dedup_check "" "$DF" "" ""); r5=$?
  [ "$r5" -eq 1 ] && pass "dedup no-session disabled" || bad "dedup no-session"
  rm -rf "$QUIET_LOG_DIR"
)

echo "== adapter: duplicate-read dedup =="
(
  export QUIET_LOG_DIR; QUIET_LOG_DIR=$(mktemp -d)
  BIG="$QUIET_LOG_DIR/big.log"
  awk 'BEGIN{for(i=0;i<4000;i++)print "line "i" some filler text to exceed the outline threshold"}' > "$BIG"
  CONTENT=$(cat "$BIG")
  EV=$(jq -n --arg p "$BIG" --rawfile t "$BIG" --arg s "sessDED" \
        '{session_id:$s, tool_name:"Read", tool_input:{file_path:$p}, tool_response:$t}')
  # first event: pass through (adapter prints nothing)
  o1=$(printf '%s' "$EV" | "$ROOT/adapters/claude-code-result.sh")
  [ -z "$o1" ] && pass "adapter first read passes through" || bad "adapter first read"
  # second identical event: deduped (adapter prints replacement with the stub)
  o2=$(printf '%s' "$EV" | "$ROOT/adapters/claude-code-result.sh")
  printf '%s' "$o2" | jq -e '.hookSpecificOutput.updatedToolOutput' >/dev/null 2>&1 \
    && printf '%s' "$o2" | grep -q 'unchanged since you read it' \
    && pass "adapter repeat read deduped" || bad "adapter repeat read"
  rm -rf "$QUIET_LOG_DIR"
)

echo "== cache-safety: rendered output is deterministic (never busts the prompt-cache prefix) =="
# quiet-bash only pays off if its rewrites don't invalidate the cached prefix.
# A rewrite is cache-safe iff identical input renders byte-identical text (any
# run-varying content — a timestamp, unstable ordering — would bust the cache and
# cost MORE). The only allowed variance is the mktemp spill PATH, which is written
# once per result and never re-rendered; we mask it before comparing.
(
  export QUIET_LOG_DIR; QUIET_LOG_DIR=$(mktemp -d)
  . "$ROOT/core/quiet-core.sh"
  # 1. command rewrites are byte-identical
  cs_ok=1
  for c in "yarn test" "cargo build --release" "git diff" "grep -r foo ." "curl https://x"; do
    [ "$(quiet_rewrite "$c")" = "$(quiet_rewrite "$c")" ] || cs_ok=0
  done
  [ "$cs_ok" = 1 ] && pass "quiet_rewrite renders identical output for identical command" || bad "quiet_rewrite is non-deterministic (cache risk)"
  # 2. source outline is byte-identical for the same file
  CSF="$QUIET_LOG_DIR/big.py"
  { echo "import os"; for i in $(seq 1 600); do echo "def f_$i(a, b): return a"; done; } > "$CSF"
  o1=$(QUIET_OUTLINE_MIN_BYTES=5000 "$ROOT/core/quiet-outline.sh" "$CSF")
  o2=$(QUIET_OUTLINE_MIN_BYTES=5000 "$ROOT/core/quiet-outline.sh" "$CSF")
  [ "$o1" = "$o2" ] && pass "quiet-outline renders identical output for identical file" || bad "quiet-outline is non-deterministic (cache risk)"
  # 3. result summary is identical once the (inevitably unique) spill path is masked
  big=$(awk 'BEGIN{for(i=0;i<4000;i++)print "{\"k\":"i",\"v\":\"row\"},"}')
  mask() { sed -E 's#'"$QUIET_LOG_PREFIX"'result-[A-Za-z0-9]+#SPILL#g'; }
  s1=$(QUIET_RESULT_MIN_BYTES=5000 quiet_result_summarize "$big" "WebFetch" | mask)
  s2=$(QUIET_RESULT_MIN_BYTES=5000 quiet_result_summarize "$big" "WebFetch" | mask)
  [ "$s1" = "$s2" ] && pass "result summary identical modulo spill path (cache-safe)" || bad "result summary varies beyond spill path (cache risk)"
  rm -rf "$QUIET_LOG_DIR"
)

echo "== command-level dedup (repeat cat of an unchanged file) =="
(
  export QUIET_LOG_DIR; QUIET_LOG_DIR=$(mktemp -d)
  . "$ROOT/core/quiet-core.sh"
  CF="$QUIET_LOG_DIR/data.txt"; printf 'hello\nworld\n' > "$CF"
  # first read: pass through (returns 1, records it)
  quiet_cmd_dedup "sessCMD" "cat $CF" >/dev/null && bad "first cat should pass through" || pass "first cat passes through"
  # second identical read of unchanged file: deduped → echoes a stub
  out=$(quiet_cmd_dedup "sessCMD" "cat $CF") \
    && printf '%s' "$out" | grep -q 'unchanged since you read it' \
    && pass "repeat cat of unchanged file deduped" || bad "repeat cat dedup"
  # after the file changes, it must read fresh again
  printf 'changed\n' >> "$CF"
  quiet_cmd_dedup "sessCMD" "cat $CF" >/dev/null && bad "changed file should re-read" || pass "changed file re-reads (no stale stub)"
  # unsafe forms pass through: pipe, redirect, multiple files, glob, no session
  printf 'a\n' > "$QUIET_LOG_DIR/a"; printf 'b\n' > "$QUIET_LOG_DIR/b"
  quiet_cmd_dedup "sessCMD" "cat $CF | head" >/dev/null && bad "piped cat dedup" || pass "piped cat passes through"
  quiet_cmd_dedup "sessCMD" "cat $QUIET_LOG_DIR/a $QUIET_LOG_DIR/b" >/dev/null && bad "multi-file cat dedup" || pass "multi-file cat passes through"
  quiet_cmd_dedup "" "cat $CF" >/dev/null && bad "no-session dedup" || pass "no-session passes through"
  # cross-tool: a Read then a cat of the same unchanged file is recognised
  printf 'x\n' > "$QUIET_LOG_DIR/shared"
  quiet_dedup_check "sessX" "$QUIET_LOG_DIR/shared" "" "" >/dev/null   # seed via Read path
  out=$(quiet_cmd_dedup "sessX" "cat $QUIET_LOG_DIR/shared") \
    && printf '%s' "$out" | grep -q 'unchanged' && pass "cat after Read deduped (shared state)" || bad "cross-tool dedup"
  rm -rf "$QUIET_LOG_DIR"
)

echo "== diff-on-reread (opt-in: QUIET_DIFF_REREAD) =="
(
  export QUIET_LOG_DIR; QUIET_LOG_DIR=$(mktemp -d)
  . "$ROOT/core/quiet-core.sh"
  base=$(awk 'BEGIN{for(i=1;i<=100;i++)print "line "i}')
  changed=$(printf '%s' "$base" | sed 's/^line 50$/line 50 EDITED/')
  huge=$(awk 'BEGIN{for(i=1;i<=100;i++)print "totally different content row "i}')
  # OFF by default → no diff, behaves as pass-through
  quiet_diff_reread "sD" "/x/f" "$base" >/dev/null && bad "diff should be off by default" || pass "diff-reread off by default"
  export QUIET_DIFF_REREAD=1
  # first read → snapshot stored, pass through
  quiet_diff_reread "sD" "/x/f" "$base" >/dev/null && bad "first read should pass through" || pass "first read snapshots + passes through"
  # small change re-read → unified diff returned, mentions the edited line
  out=$(quiet_diff_reread "sD" "/x/f" "$changed") \
    && printf '%s' "$out" | grep -q 'line 50 EDITED' \
    && printf '%s' "$out" | grep -q 'changed since you last read it' \
    && pass "changed re-read returns a unified diff" || bad "diff-reread small change"
  # identical re-read → no diff (let dedup handle it)
  quiet_diff_reread "sD" "/x/f" "$changed" >/dev/null && bad "identical re-read should pass through" || pass "identical re-read passes through"
  # massive change (diff not smaller than full) → pass full through
  quiet_diff_reread "sD" "/x/f" "$huge" >/dev/null && bad "huge change should show full" || pass "huge change shows full (diff not smaller)"
  rm -rf "$QUIET_LOG_DIR"
)

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
echo "== composition: quiet-check over a spill =="
. "$ROOT/core/quiet-core.sh"
MSG=$(quiet_run sh -c 'echo building; echo "ERROR nope"; echo "WARNING meh"; exit 1' 2>/dev/null)
LOG=$(printf '%s' "$MSG" | grep -oE "${QUIET_LOG_DIR%/}/+${QUIET_LOG_PREFIX}[A-Za-z0-9]+" | head -1)
{ [ -n "$LOG" ] && [ -f "$LOG" ]; } && pass "spill log created (check)" || bad "spill log created (check)"
out=$("$ROOT/core/quiet-check.sh" "$LOG"); st=$?
{ [ "$st" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL' && printf '%s' "$out" | grep -qE '1 error'; } \
  && pass "quiet-check recovers verdict+tally from spill" || bad "quiet-check over spill"

echo "== quiet-conf =="
QCF="$ROOT/core/quiet-conf.sh"
JF=$(mktemp); mv "$JF" "$JF.json"; JF="$JF.json"
printf '{"name":"x","scripts":{"test":"jest"},"dependencies":{"react":"18.2.0"}}' > "$JF"
[ "$("$QCF" "$JF" '.scripts.test')" = "jest" ] && pass "quiet-conf json jq-path" || bad "quiet-conf json jq-path"
[ "$("$QCF" "$JF" 'dependencies.react')" = "18.2.0" ] && pass "quiet-conf json bare-key (dot prepended)" || bad "quiet-conf json bare-key"
"$QCF" "$JF" '.nope' >/dev/null 2>&1; [ $? -eq 1 ] && pass "quiet-conf missing key exit 1" || bad "quiet-conf missing key"
EF=$(mktemp); printf 'FOO=bar\nexport TOKEN="abc123"\n' > "$EF"
[ "$("$QCF" "$EF" 'FOO')" = "bar" ] && pass "quiet-conf env plain" || bad "quiet-conf env plain"
[ "$("$QCF" "$EF" 'TOKEN')" = "abc123" ] && pass "quiet-conf env export+quotes" || bad "quiet-conf env quotes"
"$QCF" >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-conf usage exit 2" || bad "quiet-conf usage"
"$QCF" /no/such x >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-conf missing-file exit 2" || bad "quiet-conf missing-file"
# false/empty/"" values must not be misreported as "not found"
JF2=$(mktemp); mv "$JF2" "$JF2.json"; JF2="$JF2.json"
printf '{"flag":false,"empty":"","n":0}' > "$JF2"
[ "$("$QCF" "$JF2" .flag)" = "false" ] && pass "quiet-conf json false value" || bad "quiet-conf json false value"
"$QCF" "$JF2" .empty >/dev/null 2>&1; [ $? -eq 0 ] && pass "quiet-conf json empty-string exit 0" || bad "quiet-conf json empty-string exit 0"
[ "$("$QCF" "$JF2" .n)" = "0" ] && pass "quiet-conf json zero value" || bad "quiet-conf json zero value"
# syntactically bad jq path → exit 2
"$QCF" "$JF2" '.a[' >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-conf bad jq path exit 2" || bad "quiet-conf bad jq path exit 2"
# env key with regex metacharacters must not match the wrong line
EF2=$(mktemp); printf 'FOO.BAR=wrong\nFOO_BAR=right\n' > "$EF2"
[ "$("$QCF" "$EF2" 'FOO_BAR')" = "right" ] && pass "quiet-conf env key regex-escaped" || bad "quiet-conf env key regex-escaped"
rm -f "$JF" "$EF" "$JF2" "$EF2"

echo "== quiet-hist / quiet-blame =="
QH="$ROOT/core/quiet-hist.sh"; QB="$ROOT/core/quiet-blame.sh"
out=$("$QH" README.md -n 3); st=$?
{ [ "$st" -eq 0 ] && [ -n "$out" ]; } && pass "quiet-hist lists commits" || bad "quiet-hist lists"
"$QH" --pick quiet_rewrite core/quiet-core.sh >/dev/null 2>&1; [ $? -eq 0 ] && pass "quiet-hist pickaxe runs" || bad "quiet-hist pickaxe"
"$QH" >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-hist usage exit 2" || bad "quiet-hist usage"
"$QH" README.md -n abc >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-hist bad -n exit 2" || bad "quiet-hist bad -n"
out=$("$QB" README.md 1 3); st=$?
{ [ "$st" -eq 0 ] && [ -n "$out" ]; } && pass "quiet-blame shows range" || bad "quiet-blame range"
"$QB" README.md 1 >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-blame usage exit 2" || bad "quiet-blame usage"
"$QB" README.md a b >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-blame non-numeric exit 2" || bad "quiet-blame non-numeric"

echo "== round-2 skill rows =="
SKR="$ROOT/skills/deterministic-first/SKILL.md"
for tok in 'quiet-conf' 'quiet-hist' 'tsort'; do
  grep -qF "$tok" "$SKR" 2>/dev/null && pass "skill mentions $tok" || bad "skill missing $tok"
done
grep -q 'Repeated & blocking work' "$ROOT/README.md" 2>/dev/null && pass "README round-1 row intact" || bad "README row"

echo "== quiet-env =="
QE="$ROOT/core/quiet-env.sh"
out=$("$QE"); st=$?
{ [ "$st" -eq 0 ] && printf '%s' "$out" | grep -q '\[quiet-env\] platform'; } && pass "quiet-env runs + platform" || bad "quiet-env platform"
printf '%s' "$out" | grep -q 'git' && pass "quiet-env lists git CLI" || bad "quiet-env git"
ED=$(mktemp -d); ( cd "$ED" && : > pnpm-lock.yaml && "$QE" ) | grep -q 'pnpm' && pass "quiet-env detects pnpm" || bad "quiet-env pnpm"
rm -rf "$ED"

echo "== quiet-map =="
QM="$ROOT/core/quiet-map.sh"
out=$("$QM"); st=$?
{ [ "$st" -eq 0 ] && printf '%s' "$out" | grep -q '\[quiet-map\] largest'; } && pass "quiet-map size map runs" || bad "quiet-map size"
QUIET_MAP_BIG_LINES=10 "$QM" | grep -q '⚠' && pass "quiet-map flags big files" || bad "quiet-map flag"
"$QM" --churn >/dev/null 2>&1; [ $? -eq 0 ] && pass "quiet-map --churn runs in repo" || bad "quiet-map churn"
"$QM" --tree | grep -q 'core' && pass "quiet-map --tree lists dirs" || bad "quiet-map tree"
"$QM" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-map unknown flag exit 2" || bad "quiet-map unknown flag"

echo "== bench: enrichment grading =="
. "$ROOT/bench/enrichment-tasks.sh"
[ "$(fm_grade 0 'You would edit core/quiet-core.sh for that')" = pass ] && pass "fm_grade correct→pass" || bad "fm_grade correct"
[ "$(fm_grade 0 'totally unrelated')" = fail ] && pass "fm_grade wrong→fail" || bad "fm_grade wrong"
[ "$(fm_grade 99 'anything')" = fail ] && pass "fm_grade out-of-range→fail" || bad "fm_grade oor"
{ [ "${#FM_TASK_PROMPTS[@]}" -eq "${#FM_TASK_ASSERTS[@]}" ] && [ "${#FM_TASK_PROMPTS[@]}" -gt 0 ]; } && pass "fm tasks aligned" || bad "fm aligned"

echo "== bench: enrichment report =="
ft=$(mktemp)
cat > "$ft" <<'JSONL'
{"arm":"control","task":0,"rep":1,"input":2000,"output":80,"cost":0.05,"ms":9000,"turns":6,"pass":true}
{"arm":"control","task":1,"rep":1,"input":2200,"output":90,"cost":0.06,"ms":9500,"turns":6,"pass":true}
{"arm":"map","task":0,"rep":1,"input":1200,"output":70,"cost":0.03,"ms":6000,"turns":4,"pass":true}
{"arm":"map","task":1,"rep":1,"input":1300,"output":75,"cost":0.035,"ms":6200,"turns":4,"pass":true}
JSONL
frep=$(python3 "$ROOT/bench/enrichment-report.py" "$ft")
printf '%s' "$frep" | grep -q 'ZERO-REGRESSION ✓' && pass "report: equal pass-rate → zero-regression" || bad "report zero-regression"
printf '%s' "$frep" | grep -Eq 'cost -[0-9]' && pass "report: cheaper arm shows negative cost delta" || bad "report cost delta"
printf '%s' "$frep" | grep -q ' 6.0 ' && pass "report: turns column populated (not 0.0)" || bad "report turns column"
rm -f "$ft"

echo "== bench: cache-hit observability (session-savings) =="
ST=$(mktemp -d)
python3 - "$ST/s.jsonl" <<'PY'
import json,sys
# one big tool_result to clear MIN_SESSION_BYTES, plus usage with a known cache split:
# cache_read 900 / (input 100 + cache_read 900 + cache_creation 0) = 90.0%
rows=[{"message":{"content":[{"type":"tool_result","content":"x"*30000}],
       "usage":{"input_tokens":100,"cache_read_input_tokens":900,"cache_creation_input_tokens":0}}}]
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in rows)+"\n")
PY
chs=$(python3 "$ROOT/bench/session-savings.py" "$ST/s.jsonl" 2>/dev/null)
printf '%s' "$chs" | grep -q 'cache-hit rate' && pass "session-savings reports cache-hit section" || bad "cache-hit section missing"
printf '%s' "$chs" | grep -q 'pooled cache-hit:.*90.0%' && pass "cache-hit rate computed correctly (90.0%)" || bad "cache-hit rate wrong"
rm -rf "$ST"

echo "== enrichment skill rows =="
SKE="$ROOT/skills/deterministic-first/SKILL.md"
for tok in 'quiet-env' 'quiet-map'; do
  grep -qF "$tok" "$SKE" 2>/dev/null && pass "skill mentions $tok" || bad "skill missing $tok"
done
grep -q 'Orient' "$SKE" 2>/dev/null && pass "skill has orient row" || bad "skill orient row"

echo "== quiet-applies =="
QA2="$ROOT/core/quiet-applies.sh"
AR=$(mktemp -d); AP=$(mktemp)
( cd "$AR" && git init -q && git config user.email t@t && git config user.name t \
  && printf 'a\nb\nc\n' > f.txt && git add f.txt && git commit -qm init \
  && printf 'a\nB\nc\n' > f.txt && git diff > "$AP" && git checkout -q f.txt )
( cd "$AR" && "$QA2" -f "$AP" ) | grep -q 'APPLIES' && pass "quiet-applies clean → APPLIES" || bad "quiet-applies clean"
( cd "$AR" && "$QA2" -f "$AP" >/dev/null 2>&1; [ $? -eq 0 ] ) && pass "quiet-applies clean exit 0" || bad "quiet-applies exit0"
# corrupt the target so the patch no longer applies → CONFLICT exit 1
( cd "$AR" && printf 'totally\ndifferent\n' > f.txt && "$QA2" -f "$AP" >/dev/null 2>&1; [ $? -eq 1 ] ) && pass "quiet-applies conflict → exit 1" || bad "quiet-applies conflict"
( cd "$AR" && "$QA2" </dev/null >/dev/null 2>&1; [ $? -eq 2 ] ) && pass "quiet-applies empty → exit 2" || bad "quiet-applies empty"
NG=$(mktemp -d); ( cd "$NG" && printf 'x' | "$QA2" >/dev/null 2>&1; [ $? -eq 2 ] ) && pass "quiet-applies non-git → exit 2" || bad "quiet-applies non-git"
rm -rf "$AR" "$NG" "$AP"

echo "== quiet-patch =="
QP="$ROOT/core/quiet-patch.sh"
PR=$(mktemp -d); PP=$(mktemp)
( cd "$PR" && git init -q && git config user.email t@t && git config user.name t \
  && printf 'a\nb\nc\n' > f.txt && git add f.txt && git commit -qm init \
  && printf 'a\nB\nc\n' > f.txt && git diff > "$PP" && git checkout -q f.txt )
( cd "$PR" && "$QP" -f "$PP" >/dev/null && grep -q '^B$' f.txt ) && pass "quiet-patch applies + changes file" || bad "quiet-patch applies"
# re-apply same patch (already applied) → FAIL exit 1, tree untouched
before=$(cd "$PR" && cat f.txt)
( cd "$PR" && "$QP" -f "$PP" >/dev/null 2>&1; [ $? -eq 1 ] ) && pass "quiet-patch re-apply → FAIL exit 1" || bad "quiet-patch reapply"
after=$(cd "$PR" && cat f.txt); [ "$before" = "$after" ] && pass "quiet-patch FAIL leaves tree untouched" || bad "quiet-patch tree untouched"
( cd "$PR" && "$QP" </dev/null >/dev/null 2>&1; [ $? -eq 2 ] ) && pass "quiet-patch empty → exit 2" || bad "quiet-patch empty"
NGP=$(mktemp -d); ( cd "$NGP" && printf 'x' | "$QP" >/dev/null 2>&1; [ $? -eq 2 ] ) && pass "quiet-patch non-git → exit 2" || bad "quiet-patch non-git"
rm -rf "$PR" "$NGP" "$PP"

echo "== bench: dfirst-audit =="
DA="$ROOT/bench/dfirst-audit.py"
FX="$ROOT/tests/fixtures/transcripts"
python3 "$DA" "$FX/probe.jsonl" | grep -q 'quiet-env | 1 | 2' && pass "audit P4 detects probes" || bad "audit P4"
python3 "$DA" "$FX/reread.jsonl" | grep -q 'quiet-dedup | 1 | 1' && pass "audit P2 detects re-read" || bad "audit P2"
cl=$(python3 "$DA" "$FX/clean.jsonl")
{ printf '%s' "$cl" | grep -q 'quiet-env | 0 | 0' && printf '%s' "$cl" | grep -q 'quiet-dedup | 0 | 0'; } && pass "audit clean → no hits" || bad "audit clean"
BADJ=$(mktemp); printf 'not json\n{"message":{"content":[]}}\n' > "$BADJ"
python3 "$DA" "$BADJ" >/dev/null 2>&1 && pass "audit tolerates malformed lines" || bad "audit malformed"
rm -f "$BADJ"

echo "== frontier skill rows =="
SKF="$ROOT/skills/deterministic-first/SKILL.md"
for tok in 'quiet-patch' 'quiet-applies'; do
  grep -qF "$tok" "$SKF" 2>/dev/null && pass "skill mentions $tok" || bad "skill missing $tok"
done

echo "== observe (stage 1): fingerprint =="
c1=$(quiet_observe_canon 'grep -n "foo" src/a.ts')
c2=$(quiet_observe_canon 'grep -n "bar" src/b.ts')
[ "$c1" = "grep -n <STR> <PATH>" ] && pass "canon: grep normalizes literals" || bad "canon grep got: '$c1'"
[ "$c1" = "$c2" ] && pass "canon: clusters differing literals" || bad "canon cluster: '$c1' vs '$c2'"
[ "$(quiet_observe_canon '/usr/bin/curl https://x/api')" = "curl <URL>" ] && pass "canon: basenames argv0 + URL" || bad "canon url: '$(quiet_observe_canon '/usr/bin/curl https://x/api')'"
[ "$(quiet_observe_canon 'git show 1a2b3c4d')" = "git show <HASH>" ] && pass "canon: hex -> <HASH>" || bad "canon hash: '$(quiet_observe_canon 'git show 1a2b3c4d')'"
f1=$(quiet_observe_fingerprint 'npm test'); f2=$(quiet_observe_fingerprint 'npm test')
[ -n "$f1" ] && [ "$f1" = "$f2" ] && pass "fp: deterministic" || bad "fp deterministic: '$f1' vs '$f2'"
[ "$f1" != "$(quiet_observe_fingerprint 'npm run build')" ] && pass "fp: distinguishes commands" || bad "fp does not distinguish"

echo "== observe (stage 1): config flag + ledger =="
obs_tmp=$(mktemp -d)
export QUIET_OBSERVE_LEDGER="$obs_tmp/observe.jsonl"
export QUIET_CONFIG_FILE="$obs_tmp/config"
quiet_observe_enabled && bad "should be disabled without config" || pass "disabled by default (no config)"
quiet_observe_record 'npm test' 1 100
[ ! -f "$QUIET_OBSERVE_LEDGER" ] && pass "no ledger written while disabled" || bad "ledger written while disabled"
printf 'observe = on\n' > "$QUIET_CONFIG_FILE"
quiet_observe_enabled && pass "enabled via config file toggle" || bad "config toggle did not enable"
quiet_observe_record 'npm test' 1 100
quiet_observe_record 'npm test' 1 120
quiet_observe_record 'npm run build' 1 50
[ -f "$QUIET_OBSERVE_LEDGER" ] && pass "ledger created when enabled" || bad "ledger missing when enabled"
lc=$(wc -l < "$QUIET_OBSERVE_LEDGER" | tr -d ' ')
[ "$lc" = "3" ] && pass "appends one row per call (3)" || bad "row count = $lc"
head -1 "$QUIET_OBSERVE_LEDGER" | jq -e '.fp and .canon and (.bytes==100)' >/dev/null 2>&1 && pass "row is valid JSON with fp+bytes" || bad "row JSON invalid: $(head -1 "$QUIET_OBSERVE_LEDGER")"
rn=$(quiet_observe_report | awk '/npm test$/{print $1}')
[ "$rn" = "2" ] && pass "report ranks recurrence (npm test x2)" || bad "report recurrence = '$rn'"
printf 'observe = off\n' > "$QUIET_CONFIG_FILE"
quiet_observe_enabled && bad "off value should disable" || pass "observe = off disables"
unset QUIET_OBSERVE_LEDGER QUIET_CONFIG_FILE
rm -rf "$obs_tmp"

echo "== observe (stage 1): adapter integration =="
obs_tmp=$(mktemp -d)
export QUIET_OBSERVE_LEDGER="$obs_tmp/observe.jsonl"
export QUIET_CONFIG_FILE="$obs_tmp/config"
printf 'observe = on\n' > "$QUIET_CONFIG_FILE"
printf '{"tool_input":{"command":"ls -la"},"session_id":"s1"}' | bash "$ROOT/adapters/claude-code.sh" >/dev/null 2>&1
printf '{"tool_input":{"command":"npm test"},"session_id":"s1"}' | bash "$ROOT/adapters/claude-code.sh" >/dev/null 2>&1
arows=$(wc -l < "$QUIET_OBSERVE_LEDGER" 2>/dev/null | tr -d ' ')
[ "$arows" = "2" ] && pass "adapter records every bash command" || bad "adapter rows = '$arows'"
quiet_observe_report | grep -q 'npm test' && pass "adapter-recorded pattern appears in report" || bad "adapter pattern missing from report"
# disabled adapter must not write
printf 'observe = off\n' > "$QUIET_CONFIG_FILE"; : > "$QUIET_OBSERVE_LEDGER"
printf '{"tool_input":{"command":"npm test"},"session_id":"s1"}' | bash "$ROOT/adapters/claude-code.sh" >/dev/null 2>&1
[ ! -s "$QUIET_OBSERVE_LEDGER" ] && pass "adapter records nothing while disabled" || bad "adapter wrote while disabled"
unset QUIET_OBSERVE_LEDGER QUIET_CONFIG_FILE
rm -rf "$obs_tmp"

echo "== observe (stage 1): canon wrappers + CLI + quiet_run =="
[ "$(quiet_observe_canon 'command npm test')" = "npm test" ] && pass "canon strips 'command'" || bad "canon command: '$(quiet_observe_canon 'command npm test')'"
[ "$(quiet_observe_canon 'env FOO=1 npm test')" = "npm test" ] && pass "canon strips env+assignment" || bad "canon env: '$(quiet_observe_canon 'env FOO=1 npm test')'"
[ "$(quiet_observe_canon '/abs/path/pytest -q')" = "pytest -q" ] && pass "canon basenames abs argv0" || bad "canon abs: '$(quiet_observe_canon '/abs/path/pytest -q')'"
obs_tmp=$(mktemp -d)
export QUIET_OBSERVE_LEDGER="$obs_tmp/observe.jsonl"
export QUIET_CONFIG_FILE="$obs_tmp/config"
printf 'observe = on\n' > "$QUIET_CONFIG_FILE"
quiet_observe_record 'npm test' 1 100
bash "$ROOT/core/quiet-observe.sh" report | grep -q 'npm test' && pass "CLI: report runs" || bad "CLI report failed"
bash "$ROOT/core/quiet-observe.sh" status | grep -qi 'enabled' && pass "CLI: status reports enabled" || bad "CLI status: $(bash "$ROOT/core/quiet-observe.sh" status 2>&1)"
: > "$QUIET_OBSERVE_LEDGER"
quiet_run sh -c 'echo hello; echo world' >/dev/null 2>&1
qrb=$(tail -1 "$QUIET_OBSERVE_LEDGER" 2>/dev/null | jq -r '.bytes' 2>/dev/null)
{ [ -n "$qrb" ] && [ "$qrb" -gt 0 ] 2>/dev/null; } && pass "quiet_run records real bytes" || bad "quiet_run bytes='$qrb'"
unset QUIET_OBSERVE_LEDGER QUIET_CONFIG_FILE
rm -rf "$obs_tmp"

echo "== observe (stage 1): codex/gemini/copilot adapters =="
obs_tmp=$(mktemp -d)
export QUIET_OBSERVE_LEDGER="$obs_tmp/observe.jsonl"
export QUIET_CONFIG_FILE="$obs_tmp/config"
printf 'observe = on\n' > "$QUIET_CONFIG_FILE"
: > "$QUIET_OBSERVE_LEDGER"; printf '%s' '{"tool_input":{"command":"npm test"}}' | bash "$ROOT/adapters/codex.sh" >/dev/null 2>&1
[ -s "$QUIET_OBSERVE_LEDGER" ] && pass "codex adapter records" || bad "codex did not record"
: > "$QUIET_OBSERVE_LEDGER"; printf '%s' '{"tool_input":{"command":"pytest -q"}}' | bash "$ROOT/adapters/gemini.sh" >/dev/null 2>&1
[ -s "$QUIET_OBSERVE_LEDGER" ] && pass "gemini adapter records" || bad "gemini did not record"
: > "$QUIET_OBSERVE_LEDGER"; printf '%s' '{"toolName":"bash","toolArgs":"{\"command\":\"cargo build\"}"}' | bash "$ROOT/adapters/copilot.sh" >/dev/null 2>&1
[ -s "$QUIET_OBSERVE_LEDGER" ] && pass "copilot adapter records" || bad "copilot did not record"
unset QUIET_OBSERVE_LEDGER QUIET_CONFIG_FILE
rm -rf "$obs_tmp"

echo "== reuse (stage 3): eligibility =="
rtmp=$(mktemp -d); printf '{"a":1}\n' > "$rtmp/data.json"
export QUIET_REUSE_DIR="$rtmp/.quiet-cache/reuse"
export QUIET_CONFIG_FILE="$rtmp/config"; printf 'reuse = on\n' > "$QUIET_CONFIG_FILE"
quiet_reuse_enabled && pass "reuse: enabled via config" || bad "reuse flag not enabled"
( cd "$rtmp" && quiet_reuse_eligible 'jq . data.json' )      && pass "eligible: read-only cmd over a file" || bad "jq should be eligible"
( cd "$rtmp" && quiet_reuse_eligible 'rm data.json' )        && bad "rm must be denied"        || pass "denylist: rm denied"
( cd "$rtmp" && quiet_reuse_eligible 'git log data.json' )   && bad "git must be denied"       || pass "denylist: git denied"
( cd "$rtmp" && quiet_reuse_eligible 'npm test' )            && bad "npm test must be denied"  || pass "denylist: npm test denied"
( cd "$rtmp" && quiet_reuse_eligible 'jq . data.json | head')&& bad "pipe must be ineligible"  || pass "operator: pipe ineligible"
( cd "$rtmp" && quiet_reuse_eligible 'cat data.json > o' )   && bad "redirect ineligible"      || pass "operator: redirect ineligible"
( cd "$rtmp" && quiet_reuse_eligible 'echo hi' )             && bad "no-file-input ineligible" || pass "no file input → ineligible"
( cd "$rtmp" && quiet_reuse_eligible 'grep TODO *.js' )      && bad "glob-only ineligible"     || pass "glob-only input → ineligible"

echo "== reuse (stage 3): serve + tiered freshness (end-to-end) =="
rw1=$( cd "$rtmp" && quiet_reuse_rewrite 'jq -c . data.json' )
{ echo "$rw1" | grep -q 'quiet-reuse-run' && ! echo "$rw1" | grep -q serve; } && pass "miss → run+cache rewrite" || bad "miss rewrite: $rw1"
( cd "$rtmp" && eval "$rw1" >"$rtmp/o1" 2>/dev/null )
grep -q '{"a":1}' "$rtmp/o1" && pass "miss rewrite runs & outputs" || bad "miss output: $(cat "$rtmp/o1")"
rw2=$( cd "$rtmp" && quiet_reuse_rewrite 'jq -c . data.json' )
echo "$rw2" | grep -q serve && pass "second call → serve rewrite (cache hit)" || bad "hit rewrite: $rw2"
( cd "$rtmp" && eval "$rw2" >"$rtmp/o2" 2>/dev/null )
grep -q '{"a":1}' "$rtmp/o2" && pass "serve returns cached output" || bad "serve output: $(cat "$rtmp/o2")"
# tiered freshness: same-size edit (content differs) must invalidate via content-hash
printf '{"a":9}\n' > "$rtmp/data.json"
rw3=$( cd "$rtmp" && quiet_reuse_rewrite 'jq -c . data.json' )
{ echo "$rw3" | grep -q 'quiet-reuse-run' && ! echo "$rw3" | grep -q serve; } && pass "changed input → miss (content-hash tier)" || bad "stale rewrite: $rw3"
# disabled → no rewrite at all
printf 'reuse = off\n' > "$QUIET_CONFIG_FILE"
( cd "$rtmp" && quiet_reuse_rewrite 'jq -c . data.json' >/dev/null ) && bad "disabled reuse must not rewrite" || pass "reuse off → no rewrite"
unset QUIET_REUSE_DIR QUIET_CONFIG_FILE
rm -rf "$rtmp"

echo "== reuse (stage 3): adapter serves cache =="
rtmp=$(mktemp -d); printf '{"a":1}\n' > "$rtmp/data.json"
export QUIET_REUSE_DIR="$rtmp/.quiet-cache/reuse"
export QUIET_CONFIG_FILE="$rtmp/config"; printf 'reuse = on\n' > "$QUIET_CONFIG_FILE"
ev='{"tool_input":{"command":"jq -c . data.json"},"session_id":"s1"}'
o1=$( cd "$rtmp" && printf '%s' "$ev" | bash "$ROOT/adapters/claude-code.sh" 2>/dev/null )
echo "$o1" | jq -e '.hookSpecificOutput.updatedInput.command | test("quiet-reuse-run")' >/dev/null 2>&1 && pass "adapter: 1st call rewrites to run+cache" || bad "adapter reuse miss: $o1"
( cd "$rtmp" && eval "$(echo "$o1" | jq -r '.hookSpecificOutput.updatedInput.command')" >/dev/null 2>&1 )
o2=$( cd "$rtmp" && printf '%s' "$ev" | bash "$ROOT/adapters/claude-code.sh" 2>/dev/null )
echo "$o2" | jq -e '.hookSpecificOutput.updatedInput.command | test("serve")' >/dev/null 2>&1 && pass "adapter: 2nd call serves cached" || bad "adapter reuse hit: $o2"
unset QUIET_REUSE_DIR QUIET_CONFIG_FILE
rm -rf "$rtmp"

echo "== reuse (stage 3): feedback / reputation =="
rtmp=$(mktemp -d); printf 'hello world\n' > "$rtmp/f.txt"
export QUIET_REUSE_DIR="$rtmp/.quiet-cache/reuse"
export QUIET_REUSE_EVENTS="$rtmp/.quiet-cache/reuse-events.jsonl"
export QUIET_CONFIG_FILE="$rtmp/config"; printf 'reuse = on\n' > "$QUIET_CONFIG_FILE"
( cd "$rtmp" && eval "$(quiet_reuse_rewrite 'wc -w f.txt')" >/dev/null 2>&1 )   # miss → run+cache
( cd "$rtmp" && eval "$(quiet_reuse_rewrite 'wc -w f.txt')" >/dev/null 2>&1 )   # hit → serve
[ -f "$QUIET_REUSE_EVENTS" ] && pass "reuse: events ledger written" || bad "no events ledger"
h=$(jq -s '[.[]|select(.event=="hit")]|length' "$QUIET_REUSE_EVENTS" 2>/dev/null)
m=$(jq -s '[.[]|select(.event=="miss")]|length' "$QUIET_REUSE_EVENTS" 2>/dev/null)
{ [ "$h" = "1" ] && [ "$m" = "1" ]; } && pass "reuse: 1 hit + 1 miss recorded" || bad "hits=$h misses=$m"
quiet_reuse_report | grep -q 'wc -w' && pass "reuse_report shows pattern + reputation" || bad "reuse_report missing pattern"
bash "$ROOT/core/quiet-reuse.sh" report | grep -q 'wc -w' && pass "CLI: quiet-reuse report" || bad "CLI reuse report failed"
bash "$ROOT/core/quiet-reuse.sh" status | grep -qi enabled && pass "CLI: quiet-reuse status" || bad "CLI reuse status: $(bash "$ROOT/core/quiet-reuse.sh" status 2>&1)"
unset QUIET_REUSE_DIR QUIET_REUSE_EVENTS QUIET_CONFIG_FILE
rm -rf "$rtmp"

echo "== reuse (stage 3): codex/gemini/copilot serve too =="
rtmp=$(mktemp -d); printf '{"a":1}\n' > "$rtmp/d.json"
export QUIET_REUSE_DIR="$rtmp/.quiet-cache/reuse"
export QUIET_REUSE_EVENTS="$rtmp/.quiet-cache/reuse-events.jsonl"
export QUIET_CONFIG_FILE="$rtmp/config"; printf 'reuse = on\n' > "$QUIET_CONFIG_FILE"
co=$( cd "$rtmp" && printf '%s' '{"tool_input":{"command":"jq -c . d.json"}}' | bash "$ROOT/adapters/codex.sh" 2>/dev/null )
echo "$co" | jq -e '.hookSpecificOutput.updatedInput.command|test("quiet-reuse-run")' >/dev/null 2>&1 && pass "codex: reuse rewrite" || bad "codex reuse: $co"
ge=$( cd "$rtmp" && printf '%s' '{"tool_input":{"command":"jq -c . d.json"}}' | bash "$ROOT/adapters/gemini.sh" 2>/dev/null )
echo "$ge" | jq -e '.hookSpecificOutput.tool_input.command|test("quiet-reuse-run")' >/dev/null 2>&1 && pass "gemini: reuse rewrite" || bad "gemini reuse: $ge"
cp=$( cd "$rtmp" && printf '%s' '{"toolName":"bash","toolArgs":"{\"command\":\"jq -c . d.json\"}"}' | bash "$ROOT/adapters/copilot.sh" 2>/dev/null )
echo "$cp" | jq -e '.modifiedArgs.command|test("quiet-reuse-run")' >/dev/null 2>&1 && pass "copilot: reuse rewrite" || bad "copilot reuse: $cp"
unset QUIET_REUSE_DIR QUIET_REUSE_EVENTS QUIET_CONFIG_FILE
rm -rf "$rtmp"

echo "== reuse (stage 3): correctness — distinct inputs never collide =="
rtmp=$(mktemp -d); printf 'AAA\n' > "$rtmp/a.txt"; printf 'BBB\n' > "$rtmp/b.txt"
export QUIET_REUSE_DIR="$rtmp/.quiet-cache/reuse"
export QUIET_REUSE_EVENTS="$rtmp/.quiet-cache/ev.jsonl"
export QUIET_CONFIG_FILE="$rtmp/config"; printf 'reuse = on\n' > "$QUIET_CONFIG_FILE"
( cd "$rtmp" && eval "$(quiet_reuse_rewrite 'cat a.txt')" >/dev/null 2>&1 )   # cache a
outb=$( cd "$rtmp" && eval "$(quiet_reuse_rewrite 'cat b.txt')" 2>/dev/null ) # must run b, not serve a
echo "$outb" | grep -q BBB && pass "distinct files do NOT collide (no wrong hit)" || bad "WRONG HIT: cat b.txt -> $outb"
unset QUIET_REUSE_DIR QUIET_REUSE_EVENTS QUIET_CONFIG_FILE
rm -rf "$rtmp"

echo "== reuse (stage 3): disk / memory controls =="
rtmp=$(mktemp -d); mkdir -p "$rtmp/work"
printf 'xxxxxxxx\n' > "$rtmp/work/big.txt"; printf 'p\n' > "$rtmp/work/p.txt"
export QUIET_REUSE_DIR="$rtmp/reuse"
export QUIET_REUSE_EVENTS="$rtmp/ev.jsonl"
export QUIET_CONFIG_FILE="$rtmp/config"; printf 'reuse = on\n' > "$QUIET_CONFIG_FILE"
nout(){ ls "$QUIET_REUSE_DIR"/*.out 2>/dev/null | wc -l | tr -d ' '; }
# per-output cap: output bigger than cap must NOT be cached
QUIET_REUSE_MAX_OUTPUT_BYTES=3 bash -c ':' ; export QUIET_REUSE_MAX_OUTPUT_BYTES=3
( cd "$rtmp/work" && eval "$(quiet_reuse_rewrite 'cat big.txt')" >/dev/null 2>&1 )
[ "$(nout)" = "0" ] && pass "per-output cap: oversize result not cached" || bad "oversize cached ($(nout) entries)"
unset QUIET_REUSE_MAX_OUTPUT_BYTES
# gc max-entries (LRU): 3 distinct cmds, cap 2 → gc leaves <=2
printf '1\n'>"$rtmp/work/c1"; printf '2\n'>"$rtmp/work/c2"; printf '3\n'>"$rtmp/work/c3"
for ff in c1 c2 c3; do ( cd "$rtmp/work" && eval "$(quiet_reuse_rewrite "cat $ff")" >/dev/null 2>&1 ); done
[ "$(nout)" = "3" ] && pass "three distinct entries cached (keys are precise)" || bad "expected 3 entries, got $(nout)"
QUIET_REUSE_MAX_ENTRIES=2 QUIET_REUSE_TTL_MINUTES=0 quiet_reuse_gc >/dev/null 2>&1
{ [ "$(nout)" -le 2 ]; } && pass "gc evicts to max-entries cap" || bad "gc left $(nout) (>2)"
# gc TTL: backdate one entry, evict by ttl
oldf=$(ls "$QUIET_REUSE_DIR"/*.out 2>/dev/null | head -1)
touch -t 202001010000 "$oldf" "${oldf%.out}.meta" 2>/dev/null
QUIET_REUSE_TTL_MINUTES=1 QUIET_REUSE_MAX_ENTRIES=999 quiet_reuse_gc >/dev/null 2>&1
[ ! -f "$oldf" ] && pass "gc TTL evicts stale entry" || bad "TTL did not evict"
# ledger trim (memory bound): tiny cap + small keep → bounded lines
printf 'observe = on\nreuse = on\n' > "$QUIET_CONFIG_FILE"
export QUIET_OBSERVE_LEDGER="$rtmp/obs.jsonl"
export QUIET_LEDGER_MAX_BYTES=200 QUIET_LEDGER_KEEP_LINES=10
i=0; while [ "$i" -lt 60 ]; do quiet_observe_record "cmd$i f.txt" 1 100; i=$((i+1)); done
ll=$(wc -l < "$QUIET_OBSERVE_LEDGER" | tr -d ' ')
{ [ "$ll" -le 12 ]; } && pass "observe ledger trimmed to bound (<=12 lines)" || bad "ledger not bounded: $ll lines"
unset QUIET_REUSE_DIR QUIET_REUSE_EVENTS QUIET_CONFIG_FILE QUIET_OBSERVE_LEDGER QUIET_LEDGER_MAX_BYTES QUIET_LEDGER_KEEP_LINES QUIET_REUSE_MAX_ENTRIES QUIET_REUSE_TTL_MINUTES
rm -rf "$rtmp"

echo "== crystallize (stage 4): suggest skill + bundled script =="
rtmp=$(mktemp -d)
export QUIET_OBSERVE_LEDGER="$rtmp/observe.jsonl"
export QUIET_SUGGEST_DIR="$rtmp/suggestions"
export QUIET_CONFIG_FILE="$rtmp/config"; printf 'observe = on\n' > "$QUIET_CONFIG_FILE"
i=0; while [ "$i" -lt 3 ]; do quiet_observe_record 'wc -l data.txt' 1 100; i=$((i+1)); done
quiet_observe_record 'jq . x.json' 1 50
# stubbed synthesizer (deterministic stand-in for `claude -p`): consumes the prompt, emits a SKILL.md
synth="$rtmp/fakesynth.sh"
cat > "$synth" <<'S'
#!/usr/bin/env bash
cat >/dev/null
cat <<'MD'
---
name: counting-lines
description: Counts lines in a file. Use when counting lines or checking file length.
---
Run scripts/run.sh for the deterministic part.
MD
S
chmod +x "$synth"
export QUIET_SYNTH_CMD="$synth"
quiet_crystallize_suggest 1 >/dev/null 2>&1
sk=$(ls "$QUIET_SUGGEST_DIR"/*/SKILL.md 2>/dev/null | head -1)
[ -n "$sk" ] && pass "crystallize: SKILL.md written" || bad "no SKILL.md produced"
grep -q 'name: counting-lines' "$sk" 2>/dev/null && pass "crystallize: uses synthesized skill body" || bad "skill body wrong: $(cat "$sk" 2>/dev/null)"
echo "$sk" | grep -qi 'wc' && pass "crystallize: picks the TOP recurring pattern (wc, not jq)" || bad "picked wrong pattern: $sk"
scr="$(dirname "$sk")/scripts/run.sh"
{ [ -x "$scr" ] && grep -q 'wc -l data.txt' "$scr"; } && pass "crystallize: bundled script runs the recurring command" || bad "script wrong: $(cat "$scr" 2>/dev/null)"
# graceful mechanical fallback when the synthesizer is unavailable
export QUIET_SYNTH_CMD="/nonexistent/synth-xyz"; rm -rf "$QUIET_SUGGEST_DIR"
quiet_crystallize_suggest 1 >/dev/null 2>&1
sk2=$(ls "$QUIET_SUGGEST_DIR"/*/SKILL.md 2>/dev/null | head -1)
{ [ -n "$sk2" ] && grep -q '^name:' "$sk2"; } && pass "crystallize: mechanical fallback when synth missing" || bad "no fallback skill"
# no ledger → graceful message, no crash
export QUIET_OBSERVE_LEDGER="$rtmp/none.jsonl"
quiet_crystallize_suggest 1 2>&1 | grep -qi 'no observe ledger' && pass "crystallize: graceful without a ledger" || bad "no-ledger not handled"
# CLI entry
export QUIET_OBSERVE_LEDGER="$rtmp/observe.jsonl"
bash "$ROOT/core/quiet-crystallize.sh" suggest 1 >/dev/null 2>&1 && pass "CLI: quiet-crystallize runs" || bad "CLI crystallize failed"
unset QUIET_OBSERVE_LEDGER QUIET_SUGGEST_DIR QUIET_CONFIG_FILE QUIET_SYNTH_CMD
rm -rf "$rtmp"

echo "== reuse (stage 5): shadow-verify + drift retirement =="
rtmp=$(mktemp -d); mkdir -p "$rtmp/w"; printf 'NEW\n' > "$rtmp/w/f.txt"
export QUIET_REUSE_DIR="$rtmp/reuse" QUIET_REUSE_EVENTS="$rtmp/ev.jsonl"
export QUIET_CONFIG_FILE="$rtmp/config"; printf 'reuse = on\n' > "$QUIET_CONFIG_FILE"
mkdir -p "$QUIET_REUSE_DIR"
# forge a STALE entry: .out says OLD, but meta records the CURRENT (NEW) input sig,
# so plain freshness passes — only a shadow re-run can catch this drift.
( cd "$rtmp/w" && k=$(_quiet_reuse_key 'cat f.txt'); printf 'OLD\n' > "$QUIET_REUSE_DIR/$k.out"; quiet_reuse_store "$k" 'cat f.txt' 0 )
out=$( cd "$rtmp/w" && QUIET_REUSE_VERIFY_EVERY=1 eval "$(quiet_reuse_rewrite 'cat f.txt')" 2>/dev/null )
echo "$out" | grep -q NEW && pass "drift: serves FRESH output on mismatch" || bad "drift served: '$out'"
k=$( cd "$rtmp/w" && _quiet_reuse_key 'cat f.txt' )
[ ! -f "$QUIET_REUSE_DIR/$k.out" ] && pass "drift: stale entry retired (evicted)" || bad "entry not retired"
[ "$(jq -s '[.[]|select(.event=="drift")]|length' "$QUIET_REUSE_EVENTS" 2>/dev/null)" = "1" ] && pass "drift: event logged" || bad "no drift event"
# verify-ok: a matching re-run keeps the entry
( cd "$rtmp/w" && eval "$(quiet_reuse_rewrite 'cat f.txt')" >/dev/null 2>&1 )   # miss → cache NEW
out2=$( cd "$rtmp/w" && QUIET_REUSE_VERIFY_EVERY=1 eval "$(quiet_reuse_rewrite 'cat f.txt')" 2>/dev/null )
echo "$out2" | grep -q NEW && pass "verify-ok: matching re-run still serves" || bad "verify-ok out: '$out2'"
k=$( cd "$rtmp/w" && _quiet_reuse_key 'cat f.txt' )
[ -f "$QUIET_REUSE_DIR/$k.out" ] && pass "verify-ok: entry retained" || bad "entry wrongly evicted"
unset QUIET_REUSE_DIR QUIET_REUSE_EVENTS QUIET_CONFIG_FILE
rm -rf "$rtmp"

echo "== crystallize (stage 5): skill verify (result / cost / time) =="
rtmp=$(mktemp -d); mkdir -p "$rtmp/sk/scripts"; seq 1 7 > "$rtmp/data.txt"
cat > "$rtmp/sk/scripts/run.sh" <<'S'
#!/usr/bin/env bash
set -euo pipefail
wc -l data.txt
S
chmod +x "$rtmp/sk/scripts/run.sh"
v=$( cd "$rtmp" && quiet_crystallize_verify sk 2>&1 )
echo "$v" | grep -q 'verdict:.*PASS' && pass "skill verify: PASS on a working skill" || bad "verify: $v"
echo "$v" | grep -qi 'matches baseline' && pass "skill verify: differential matches baseline (result correct)" || bad "no baseline match: $v"
echo "$v" | grep -qE 'time:[[:space:]]+[0-9]+ ms' && pass "skill verify: reports time (ms)" || bad "no time: $v"
echo "$v" | grep -qE 'result:[[:space:]]+[0-9]+ bytes' && pass "skill verify: reports cost (bytes)" || bad "no bytes: $v"
rm "$rtmp/data.txt"
vf=$( cd "$rtmp" && quiet_crystallize_verify sk 2>&1 )
echo "$vf" | grep -q 'verdict:.*FAIL' && pass "skill verify: FAIL when the script errors" || bad "should FAIL: $vf"
rm -rf "$rtmp"

echo
[ "$fail" -eq 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
