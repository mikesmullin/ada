import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { startPromptControl, callPromptControl } from '../lib/prompt-control.mjs';
import { createAdaMcp } from '../ada-mcp.mjs';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';

test('prompt control queues one job, dedupes requestId, and refuses barge-in', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'ada-prompt-'));
  const socketPath = path.join(dir, 'prompt.sock');
  let busy = false;
  let started = 0;
  const { close } = await startPromptControl({
    socketPath,
    isBusy: () => busy,
    sessionId: () => 'sess',
    onPrompt: async (job) => {
      started++;
      await new Promise((r) => setTimeout(r, 40));
      return { status: 'completed', reply: `echo:${job.prompt}`, sessionId: 'sess', turnId: 1 };
    },
  });
  try {
    const first = await callPromptControl({ cmd: 'prompt', prompt: 'hello', requestId: 'r1' }, { socketPath });
    assert.equal(first.ok, true);
    const dup = await callPromptControl({ cmd: 'prompt', prompt: 'hello', requestId: 'r1' }, { socketPath });
    assert.equal(dup.job.id, first.job.id);
    const conflict = await callPromptControl({ cmd: 'prompt', prompt: 'other', requestId: 'r1' }, { socketPath });
    assert.equal(conflict.code, 'REQUEST_CONFLICT');
    const busyRes = await callPromptControl({ cmd: 'prompt', prompt: 'two', requestId: 'r2' }, { socketPath });
    assert.equal(busyRes.code, 'BUSY');
    for (let i = 0; i < 40; i++) {
      const st = await callPromptControl({ cmd: 'status', jobId: first.job.id }, { socketPath });
      if (st.job?.status === 'completed') {
        assert.equal(st.job.result.reply, 'echo:hello');
        break;
      }
      await new Promise((r) => setTimeout(r, 20));
    }
    assert.equal(started, 1);
    busy = true;
    const later = await callPromptControl({ cmd: 'prompt', prompt: 'later', requestId: 'r3' }, { socketPath });
    assert.equal(later.code, 'BUSY');
  } finally {
    await close();
    await rm(dir, { recursive: true, force: true });
  }
});

test('ada-mcp stdio tools are a reverse interface and never barge in', async () => {
  const jobs = new Map();
  const server = createAdaMcp(async (req) => {
    if (req.cmd === 'status') return { ok: true, ready: true, sessionId: 'sess', job: req.jobId ? jobs.get(req.jobId) : undefined };
    const job = { id: 'job-1', requestId: req.requestId, prompt: req.prompt, status: 'running' };
    jobs.set(job.id, job);
    return { ok: true, job };
  });
  const client = new Client({ name: 't', version: '1' });
  const [c, s] = InMemoryTransport.createLinkedPair();
  await server.connect(s);
  await client.connect(c);
  const listed = await client.listTools();
  assert.deepEqual(listed.tools.map((t) => t.name), ['ada_prompt', 'ada_prompt_status']);
  const submitted = await client.callTool({ name: 'ada_prompt', arguments: { prompt: 'seek the video', requestId: 'op-1' } });
  assert.equal(submitted.isError, false);
  assert.match(submitted.content[0].text, /job-1/);
  await client.close();
  await server.close();
});
