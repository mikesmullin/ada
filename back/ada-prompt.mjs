#!/usr/bin/env node
// One-shot CLI that really uses the external MCP stdio server.
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
const args = process.argv.slice(2);
if (!args.length) { console.error('usage: node back/ada-prompt.mjs "prompt" | --status [jobId]'); process.exit(1); }
const status = args[0] === '--status';
const client = new Client({ name: 'ada-prompt-cli', version: '0.1.0' });
const transport = new StdioClientTransport({ command: process.execPath, args: [fileURLToPath(new URL('./ada-mcp.mjs', import.meta.url))], env: { ...process.env }, stderr: 'inherit' });
try {
  await client.connect(transport);
  const result = await client.callTool({ name: status ? 'ada_prompt_status' : 'ada_prompt', arguments: status ? (args[1] ? { jobId: args[1] } : {}) : { prompt: args.join(' '), requestId: randomUUID() } });
  console.log(result.content.map((p) => p.text || '').join('\n'));
  process.exitCode = result.isError ? 1 : 0;
} finally { await client.close(); }
