#!/usr/bin/env node
//
// quiet-mcp-tools-proxy — PROTOTYPE. Defers MCP tool *schemas*, not just results.
//
//   node quiet-mcp-tools-proxy.mjs <upstream-command> [args...]
//
// A server with many tools re-sends every tool's full JSON Schema on every
// turn (it's part of the system prompt). This proxy exposes exactly three
// meta-tools to the client instead of the server's real tool list:
//
//   list_tools()                 -> names + one-line descriptions only
//   get_tool_schema({name})      -> full inputSchema for one real tool
//   call_tool({name, arguments}) -> invokes the real tool on the upstream server
//
// The model must call list_tools (and optionally get_tool_schema) before it
// can call_tool — one extra round-trip per session, in exchange for never
// carrying N real tool schemas in the system prompt. This is the "search
// first" pattern (cf. Atlassian mcp-compressor, Anthropic's Tool Search Tool),
// ported to any MCP client at the transport layer — no client-specific
// re-fetch/list_changed behavior required.
//
// Status: PROTOTYPE for bench/mcp-schema-deferral.sh — built to measure real
// token/cost impact before committing to a production feature. See
// docs/research/cost-levers-2026-07-update.md (candidate #1) and
// bench/RESULTS.md for the live A/B this was built to answer.
//
// Large call_tool results are still collapsed via core/quiet-result.sh, same
// as quiet-mcp-proxy.mjs. Non-tools/list, non-tools/call traffic (initialize,
// notifications, etc.) passes through verbatim.
//
// Requires: node, bash, jq (jq used by the result summarizer).

import { spawn, execFileSync } from 'node:child_process'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const SUMMARIZER = join(__dirname, '..', 'core', 'quiet-result.sh')
const MIN_BYTES = Number(process.env.QUIET_RESULT_MIN_BYTES || 25000)

const [cmd, ...args] = process.argv.slice(2)
if (!cmd) {
  process.stderr.write('usage: quiet-mcp-tools-proxy.mjs <upstream-command> [args...]\n')
  process.exit(2)
}

const child = spawn(cmd, args, { stdio: ['pipe', 'pipe', 'inherit'] })
child.on('exit', (code) => process.exit(code ?? 0))
child.on('error', (e) => { process.stderr.write(`quiet-mcp-tools-proxy: ${e.message}\n`); process.exit(1) })

const writeChild = (obj) => child.stdin.write(JSON.stringify(obj) + '\n')
const writeClient = (obj) => process.stdout.write(JSON.stringify(obj) + '\n')

const META_TOOLS = [
  {
    name: 'list_tools',
    description: 'List available tool names with a one-line description each. Call this first to discover what this server can do.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'get_tool_schema',
    description: 'Get the full input schema for one real tool, by name (as returned by list_tools).',
    inputSchema: { type: 'object', properties: { name: { type: 'string' } }, required: ['name'] },
  },
  {
    name: 'call_tool',
    description: 'Invoke one real tool by name with its arguments (fetch the schema via get_tool_schema first).',
    inputSchema: {
      type: 'object',
      properties: { name: { type: 'string' }, arguments: { type: 'object' } },
      required: ['name'],
    },
  },
]

// Real upstream tool list, fetched lazily on first need.
let realTools = null
let realToolsPromise = null
let nextInternalId = 1
const internalPending = new Map()  // proxy-generated id -> resolver
const forwardedCalls = new Map()   // proxy-generated id -> {clientId, name}

function fetchRealTools() {
  if (realTools) return Promise.resolve(realTools)
  if (realToolsPromise) return realToolsPromise
  const id = `__qlist${nextInternalId++}`
  realToolsPromise = new Promise((resolve) => {
    internalPending.set(id, (result) => {
      realTools = (result && result.tools) || []
      resolve(realTools)
    })
  })
  writeChild({ jsonrpc: '2.0', id, method: 'tools/list', params: {} })
  return realToolsPromise
}

function shrinkText(name, text) {
  if (!text || Buffer.byteLength(text, 'utf8') <= MIN_BYTES) return text
  try {
    const summary = execFileSync('bash', [SUMMARIZER, name], { input: text, maxBuffer: 1 << 30 }).toString()
    return summary.trim() ? summary : text
  } catch {
    return text
  }
}

async function handleMetaCall(clientId, name, toolArgs) {
  if (name === 'list_tools') {
    const tools = await fetchRealTools()
    const text = tools.map((t) => `${t.name}: ${t.description || ''}`).join('\n')
    writeClient({ jsonrpc: '2.0', id: clientId, result: { content: [{ type: 'text', text }] } })
    return
  }
  if (name === 'get_tool_schema') {
    const tools = await fetchRealTools()
    const tool = tools.find((t) => t.name === toolArgs.name)
    const text = tool ? JSON.stringify(tool.inputSchema || {}) : `no such tool: ${toolArgs.name}`
    writeClient({ jsonrpc: '2.0', id: clientId, result: { content: [{ type: 'text', text }] } })
    return
  }
  if (name === 'call_tool') {
    const realName = toolArgs.name
    const realArgs = toolArgs.arguments || {}
    const id = `__qcall${nextInternalId++}`
    forwardedCalls.set(id, { clientId, name: realName })
    writeChild({ jsonrpc: '2.0', id, method: 'tools/call', params: { name: realName, arguments: realArgs } })
    return
  }
  writeClient({ jsonrpc: '2.0', id: clientId, error: { code: -32602, message: `unknown meta-tool: ${name}` } })
}

// client -> upstream
createInterface({ input: process.stdin }).on('line', (line) => {
  if (line === '') return
  let msg
  try { msg = JSON.parse(line) } catch { child.stdin.write(line + '\n'); return }

  if (msg.method === 'tools/list' && msg.id !== undefined) {
    writeClient({ jsonrpc: '2.0', id: msg.id, result: { tools: META_TOOLS } })
    return
  }
  if (msg.method === 'tools/call' && msg.id !== undefined) {
    const name = msg.params && msg.params.name
    if (name === 'list_tools' || name === 'get_tool_schema' || name === 'call_tool') {
      handleMetaCall(msg.id, name, (msg.params && msg.params.arguments) || {})
      return
    }
  }
  // initialize, notifications, or anything else: pass through verbatim.
  child.stdin.write(line + '\n')
})

// upstream -> client
createInterface({ input: child.stdout }).on('line', (line) => {
  if (line === '') return
  let msg
  try { msg = JSON.parse(line) } catch { process.stdout.write(line + '\n'); return }

  if (msg.id !== undefined && internalPending.has(msg.id)) {
    internalPending.get(msg.id)(msg.result)
    internalPending.delete(msg.id)
    return
  }
  if (msg.id !== undefined && forwardedCalls.has(msg.id)) {
    const { clientId, name } = forwardedCalls.get(msg.id)
    forwardedCalls.delete(msg.id)
    if (msg.result && Array.isArray(msg.result.content)) {
      for (const c of msg.result.content) {
        if (c && c.type === 'text' && typeof c.text === 'string') c.text = shrinkText(name, c.text)
      }
    }
    writeClient({ ...msg, id: clientId })
    return
  }
  // not one of ours: pass through verbatim.
  process.stdout.write(line + '\n')
})
