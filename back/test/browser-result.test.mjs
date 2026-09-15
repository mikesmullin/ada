import { test } from 'node:test';
import assert from 'node:assert/strict';
import { browserResult } from '../lib/browser-result.mjs';

test('browser screenshots reach the model as image parts, not [image]', () => {
  const content = browserResult({ content: [
    { type: 'text', text: '/tmp/screenshot.png' },
    { type: 'image', mimeType: 'image/png', data: 'aGVsbG8=' },
  ] }, 'test:vision-model');
  assert.deepEqual(content, [
    { type: 'text', text: '/tmp/screenshot.png' },
    { type: 'image_url', image_url: { url: 'data:image/png;base64,aGVsbG8=' } },
  ]);
});

test('text results remain text; MCP errors throw with structured error code', () => {
  assert.equal(browserResult({ content: [{ type: 'text', text: 'hello' }] }), 'hello');
  assert.throws(() => browserResult({
    isError: true,
    content: [{ type: 'text', text: 'Take a new snapshot' }],
    structuredContent: { response: { data: { code: 'STALE_REF' } } },
  }), { code: 'STALE_REF', message: 'STALE_REF: Take a new snapshot' });
});
