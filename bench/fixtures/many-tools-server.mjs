#!/usr/bin/env node
//
// many-tools-server.mjs — a minimal, spec-compliant MCP server (stdio JSON-RPC)
// exposing many tools with realistic-sized schemas, for benchmarking whether
// deferring tool-schema loading actually reduces LLM input tokens/cost.
//
// Deterministic: N tools with a templated schema (no real functionality beyond
// echoing), plus one findable "target" tool a benchmark task can call and whose
// output is easy to verify.
//
// Usage: node many-tools-server.mjs [toolCount]

import { createInterface } from 'node:readline'

const N = Number(process.argv[2] || 40)

function makeTool(i) {
  const name = `project_tool_${i}`
  return {
    name,
    description: `Manage resource set #${i} in the project-tracking API: query, filter, and paginate records.`,
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'Free-text search query' },
        limit: { type: 'integer', description: 'Max records to return', default: 20 },
        offset: { type: 'integer', description: 'Pagination offset', default: 0 },
        filter: {
          type: 'object',
          description: 'Structured filter',
          properties: {
            status: { type: 'string', enum: ['open', 'closed', 'archived'] },
            owner: { type: 'string' },
          },
        },
        sort: { type: 'string', enum: ['created_at', 'updated_at', 'priority'], default: 'updated_at' },
      },
      required: ['query'],
    },
  }
}

const TARGET_TOOL = {
  name: 'get_secret_code',
  description: 'Look up the secret code for a given numeric id.',
  inputSchema: {
    type: 'object',
    properties: { id: { type: 'integer', description: 'The lookup id' } },
    required: ['id'],
  },
}

const TOOLS = [...Array.from({ length: N }, (_, i) => makeTool(i + 1)), TARGET_TOOL]

const write = (obj) => process.stdout.write(JSON.stringify(obj) + '\n')

createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line) return
  let msg
  try { msg = JSON.parse(line) } catch { return }
  const { id, method, params } = msg
  if (method === 'initialize') {
    write({
      jsonrpc: '2.0', id,
      result: {
        protocolVersion: (params && params.protocolVersion) || '2025-06-18',
        capabilities: { tools: {} },
        serverInfo: { name: 'many-tools-server', version: '1.0.0' },
      },
    })
  } else if (method === 'notifications/initialized') {
    // no response required
  } else if (method === 'tools/list') {
    write({ jsonrpc: '2.0', id, result: { tools: TOOLS } })
  } else if (method === 'tools/call') {
    const name = params && params.name
    const args = (params && params.arguments) || {}
    let text
    if (name === 'get_secret_code') {
      text = args.id === 42 ? 'SECRET-42-XYZZY' : `no secret code for id ${args.id}`
    } else {
      text = `ok: ${name} called with ${JSON.stringify(args)} — 0 records found`
    }
    write({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text }] } })
  } else if (id !== undefined) {
    write({ jsonrpc: '2.0', id, error: { code: -32601, message: `method not found: ${method}` } })
  }
})
