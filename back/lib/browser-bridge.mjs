import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { spawn } from 'node:child_process';

export class BrowserBridge {
  constructor({ url = process.env.MCP_ZEN_URL || 'http://localhost:8791/mcp', connect, start } = {}) {
    this.url = url;
    this.client = null;
    this.tools = [];
    this.checking = null;
    this.connect = connect || (async () => {
      const client = new Client({ name: 'ada-back', version: '0.2.0' });
      try { await client.connect(new StreamableHTTPClientTransport(new URL(url)), { timeout: 3000 }); return client; }
      catch (error) { await client.close().catch(() => {}); throw error; }
    });
    this.start = start || (() => {
      if (!['localhost', '127.0.0.1', '[::1]'].includes(new URL(url).hostname)) throw new Error('Remote MCP Zen is unavailable; not starting a local replacement');
      const child = spawn('mcp-zen', [], { detached: true, stdio: 'ignore' });
      child.on('error', (e) => console.error(`mcp-zen startup: ${e.message}`));
      child.unref();
    });
  }
  async ensure() {
    if (this.checking) return this.checking;
    this.checking = this.check().finally(() => { this.checking = null; });
    return this.checking;
  }
  async check() {
    if (this.client) {
      try { await this.client.ping({ timeout: 2000 }); return true; }
      catch { await this.invalidate(this.client); }
    }
    for (let attempt = 0; attempt < 10; attempt++) {
      let candidate;
      try {
        candidate = await this.connect();
        const { tools } = await candidate.listTools({}, { timeout: 3000 });
        this.tools = tools;
        this.client = candidate;
        return true;
      } catch (error) {
        await candidate?.close().catch(() => {});
        if (attempt === 0) this.start();
        if (attempt === 9) throw new Error(`MCP Zen unavailable: ${error.message}`);
        await new Promise((r) => setTimeout(r, 500));
      }
    }
  }
  async invalidate(client) {
    if (this.client === client) this.client = null;
    await client?.close().catch(() => {});
  }
  async call(name, args, { signal } = {}) {
    signal?.throwIfAborted();
    await this.ensure();
    signal?.throwIfAborted();
    if (!this.tools.some((t) => t.name === name)) throw new Error(`Browser tool ${name} is no longer available after reconnect; restart Ada to refresh its catalog`);
    const client = this.client;
    try {
      // Never replay: a lost response may follow a successfully dispatched click.
      return await client.callTool({ name, arguments: args }, undefined, { signal, timeout: Math.min(args.timeoutMs ?? 15000, 120000) + 1000 });
    } catch (error) {
      await this.invalidate(client);
      throw new Error(`Browser transport failure: ${error.message}. Action outcome may be unknown; inspect state before retrying.`);
    }
  }
}
