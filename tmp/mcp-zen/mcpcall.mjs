#!/usr/bin/env node
// CLI helper: one MCP tool call per invocation over Streamable HTTP against
// the persistent mcp-zen server. Each run opens its own short-lived session
// (cheap -- the extension's WebSocket connection to the server is entirely
// separate and stays up regardless).
// usage: node mcpcall.mjs <tool_name> '<json_args>'
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const [, , toolName, argsJson] = process.argv;
if (!toolName) {
  console.error("usage: node mcpcall.mjs <tool_name> '<json_args>'");
  process.exit(1);
}
const args = argsJson ? JSON.parse(argsJson) : {};
const url = process.env.MCP_ZEN_URL || "http://localhost:8791/mcp";

const transport = new StreamableHTTPClientTransport(new URL(url));
const client = new Client({ name: "mcpcall-cli", version: "0.0.1" });
await client.connect(transport);

const result = await client.callTool({ name: toolName, arguments: args });
console.log(JSON.stringify(result, null, 2));

await client.close();
process.exit(result.isError ? 1 : 0);
