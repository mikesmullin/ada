#!/usr/bin/env node
// External MCP server. Deliberately NOT in Ada's own tool catalog.
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { pathToFileURL } from 'node:url';
import { callPromptControl } from './lib/prompt-control.mjs';

export function createAdaMcp(call = callPromptControl) {
  const server = new Server({ name: 'ada-prompt', version: '0.1.0' }, { capabilities: { tools: {} }, instructions: 'Prompt the running Ada session via local same-user IPC. Not TTS-only and not a new agent. Prompts run with normal tool approval policy. Submit once with a unique requestId, poll status. Busy requests never interrupt. Disconnect does not cancel an accepted job. Jobs are in-memory, last 30, lost on backend restart. Do not install this server into Ada herself.' });
  const tools = [
    { name: 'ada_prompt', description: 'Submit a prompt to Ada\'s existing conversation. Returns a job ID immediately; poll ada_prompt_status for the reply. Does not bypass tool approvals. Silent by default. Same requestId deduplicates retries.', inputSchema: { type: 'object', properties: { prompt: { type: 'string', minLength: 1, maxLength: 16000 }, requestId: { type: 'string', pattern: '^[a-zA-Z0-9_-]{1,80}$' }, speak: { type: 'boolean', default: false } }, required: ['prompt', 'requestId'], additionalProperties: false }, annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: true } },
    { name: 'ada_prompt_status', description: 'Read a submitted prompt job and Ada\'s final reply. Omit jobId to check readiness/session ID. A completed turn is not proof that its browser task succeeded; inspect reply and session tool evidence.', inputSchema: { type: 'object', properties: { jobId: { type: 'string', minLength: 1 } }, additionalProperties: false }, annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false } },
  ];
  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));
  server.setRequestHandler(CallToolRequestSchema, async ({ params }, extra) => {
    try {
      const args = params.arguments || {};
      if (!tools.some((t) => t.name === params.name)) throw new Error('Unknown tool');
      const allowed = params.name === 'ada_prompt' ? ['prompt', 'requestId', 'speak'] : ['jobId'];
      if (Object.keys(args).some((k) => !allowed.includes(k))) throw new Error('Unexpected argument');
      if (args.jobId !== undefined && (typeof args.jobId !== 'string' || !args.jobId)) throw new Error('jobId must be a nonempty string');
      const result = await call({ ...args, cmd: params.name === 'ada_prompt' ? 'prompt' : 'status' }, { signal: extra.signal });
      return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }], isError: !result.ok };
    } catch (error) { return { content: [{ type: 'text', text: `Ada prompt error: ${error.message}` }], isError: true }; }
  });
  return server;
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await createAdaMcp().connect(new StdioServerTransport());
