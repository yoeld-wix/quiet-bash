#!/usr/bin/env node
//
// quiet-mcp-proxy — a transport-level MCP proxy that shrinks large tool results.
//
//   node quiet-mcp-proxy.mjs <upstream-command> [args...]
//
// It speaks MCP (newline-delimited JSON-RPC over stdio) to the agent/client and
// spawns the real MCP server as a child, forwarding every message verbatim —
// EXCEPT `tools/call` responses: when a result's text is large, the byte-exact
// payload is spilled to a file and the result is replaced with a compact summary
// (reusing core/quiet-result.sh, the same summarizer the hook adapters use).
//
// This is the client-agnostic path: it works for ANY MCP client, including ones
// that can't rewrite results via a hook (e.g. Codex). Lossless — only the
// preview shrinks; the full payload stays on disk and the summary says how to
// query it. Configure your client to launch this instead of the real server.
//
// Requires: node, bash, jq (jq used by the summarizer).

import { spawn, execFileSync } from 'node:child_process'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const SUMMARIZER = join(__dirname, '..', 'core', 'quiet-result.sh')
const MIN_BYTES = Number(process.env.QUIET_RESULT_MIN_BYTES || 25000)

const [cmd, ...args] = process.argv.slice(2)
if (!cmd) {
  process.stderr.write('usage: quiet-mcp-proxy.mjs <upstream-command> [args...]\n')
  process.exit(2)
}

const child = spawn(cmd, args, { stdio: ['pipe', 'pipe', 'inherit'] })
child.on('exit', (code) => process.exit(code ?? 0))
child.on('error', (e) => { process.stderr.write(`quiet-mcp-proxy: ${e.message}\n`); process.exit(1) })

// id -> tool name, recorded from client tools/call requests.
const pending = new Map()

const writeChild = (line) => child.stdin.write(line + '\n')
const writeClient = (line) => process.stdout.write(line + '\n')

// Replace a large tool-result with a summary; returns the (possibly) edited msg.
function maybeShrink(msg) {
  try {
    const name = pending.get(msg.id)
    pending.delete(msg.id)
    if (name === undefined) return msg                  // not a tools/call response
    const result = msg.result
    if (!result || !Array.isArray(result.content)) return msg
    const text = result.content
      .filter((c) => c && c.type === 'text' && typeof c.text === 'string')
      .map((c) => c.text)
      .join('\n')
    if (!text || Buffer.byteLength(text, 'utf8') <= MIN_BYTES) return msg
    let summary
    try {
      summary = execFileSync('bash', [SUMMARIZER, name], { input: text, maxBuffer: 1 << 30 }).toString()
    } catch {
      return msg                                          // summarizer failed → leave untouched
    }
    if (!summary.trim()) return msg
    result.content = [{ type: 'text', text: summary }]
    delete result.structuredContent                       // avoid re-inlining the bulk
    return msg
  } catch {
    return msg
  }
}

// client → upstream: forward verbatim, but record tools/call ids.
createInterface({ input: process.stdin }).on('line', (line) => {
  if (line === '') return
  try {
    const msg = JSON.parse(line)
    if (msg && msg.method === 'tools/call' && msg.id !== undefined) {
      pending.set(msg.id, (msg.params && msg.params.name) || 'tool')
    }
  } catch { /* non-JSON → forward as-is */ }
  writeChild(line)
})

// upstream → client: forward verbatim, but shrink large tools/call responses.
createInterface({ input: child.stdout }).on('line', (line) => {
  if (line === '') return
  let out = line
  try {
    const msg = JSON.parse(line)
    if (msg && msg.id !== undefined && pending.has(msg.id) && msg.result) {
      out = JSON.stringify(maybeShrink(msg))
    }
  } catch { /* non-JSON → forward as-is */ }
  writeClient(out)
})
