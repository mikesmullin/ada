import net from 'node:net';
import { randomUUID } from 'node:crypto';
import { mkdir, lstat, chmod, unlink } from 'node:fs/promises';
import path from 'node:path';

export const promptSocketPath = () => process.env.ADA_PROMPT_SOCK || path.join(process.env.XDG_RUNTIME_DIR || `/tmp/ada-${process.getuid()}`, 'ada', 'prompt.sock');

// Same-user local control only. Jobs survive short-lived MCP client sessions,
// not backend restarts. Submission does not interrupt a voice/tool turn.
export async function startPromptControl({ socketPath = promptSocketPath(), isBusy, onPrompt, sessionId }) {
  const dir = path.dirname(socketPath);
  await mkdir(dir, { recursive: true, mode: 0o700 });
  await chmod(dir, 0o700);
  const stat = await lstat(dir);
  if (!stat.isDirectory() || stat.uid !== process.getuid()) throw new Error('Ada prompt socket directory must be owned by this user');
  try { await unlink(socketPath); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  const jobs = new Map();
  let active = null;
  const dispatch = (req) => {
    if (req.cmd === 'status') {
      if (!req.jobId) return { ok: true, ready: !active && !isBusy(), sessionId: sessionId(), activeJobId: active };
      const job = jobs.get(req.jobId);
      return job ? { ok: true, job } : { ok: false, code: 'UNKNOWN_JOB', error: 'Unknown job (jobs expire on backend restart)' };
    }
    if (req.cmd !== 'prompt') return { ok: false, code: 'BAD_REQUEST', error: 'Unknown command' };
    if (typeof req.prompt !== 'string' || !req.prompt.trim() || req.prompt.length > 16000 || (req.speak !== undefined && typeof req.speak !== 'boolean')) return { ok: false, code: 'BAD_REQUEST', error: 'prompt must be 1..16000 characters; speak must be boolean' };
    if (typeof req.requestId !== 'string' || !/^[a-zA-Z0-9_-]{1,80}$/.test(req.requestId)) return { ok: false, code: 'BAD_REQUEST', error: 'A requestId (1..80 alphanumeric/_/-) is required for deduplication' };
    const prior = [...jobs.values()].find((j) => j.requestId === req.requestId);
    if (prior) return prior.prompt === req.prompt && prior.speak === Boolean(req.speak) ? { ok: true, job: prior } : { ok: false, code: 'REQUEST_CONFLICT', error: 'requestId already used for a different prompt' };
    if (active || isBusy()) return { ok: false, code: 'BUSY', error: 'Ada is busy/listening. Wait; external prompts never barge in.' };
    while (jobs.size >= 30) jobs.delete(jobs.keys().next().value);
    const job = { id: randomUUID(), requestId: req.requestId, prompt: req.prompt, speak: Boolean(req.speak), status: 'running', sessionId: sessionId(), startedAt: new Date().toISOString() };
    jobs.set(job.id, job);
    active = job.id;
    Promise.resolve().then(() => onPrompt(job)).then((result) => {
      job.result = result;
      job.status = result?.status || 'completed';
    }, (error) => { job.status = 'failed'; job.error = String(error.message || error); }).finally(() => { job.finishedAt = new Date().toISOString(); active = null; });
    return { ok: true, job: { ...job } };
  };
  const server = net.createServer((sock) => {
    let buffer = '';
    sock.setEncoding('utf8');
    sock.setTimeout(5000, () => sock.destroy());
    sock.on('error', () => {});
    sock.on('data', (chunk) => {
      buffer += chunk;
      if (buffer.length > 70000) return sock.destroy();
      if (!buffer.includes('\n')) return;
      try { sock.end(JSON.stringify(dispatch(JSON.parse(buffer.split('\n')[0]))) + '\n'); }
      catch { sock.end(JSON.stringify({ ok: false, code: 'BAD_JSON', error: 'Invalid request' }) + '\n'); }
      sock.removeAllListeners('data');
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
  await chmod(socketPath, 0o600);
  return { close: async () => { server.close(); await unlink(socketPath).catch(() => {}); }, socketPath };
}

export function callPromptControl(request, { socketPath = promptSocketPath(), signal } = {}) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(signal.reason);
    const sock = net.connect(socketPath);
    let buffer = '';
    const abort = () => sock.destroy(new Error('Prompt transport cancelled; submission may already have been accepted. Query status; do not resubmit with a new requestId.'));
    const finish = (error, data) => { signal?.removeEventListener('abort', abort); sock.destroy(); error ? reject(error) : resolve(data); };
    signal?.addEventListener('abort', abort, { once: true });
    sock.setEncoding('utf8');
    sock.setTimeout(5000, () => sock.destroy(new Error('Ada prompt control timeout')));
    sock.on('connect', () => sock.write(JSON.stringify(request) + '\n'));
    sock.on('data', (chunk) => {
      buffer += chunk;
      if (buffer.length > 256000) return finish(new Error('Ada prompt result too large'));
      if (buffer.includes('\n')) { try { finish(null, JSON.parse(buffer.split('\n')[0])); } catch (e) { finish(e); } }
    });
    sock.on('error', (error) => finish(error));
    sock.on('end', () => { if (!buffer.includes('\n')) finish(new Error('Ada disconnected before replying')); });
  });
}
