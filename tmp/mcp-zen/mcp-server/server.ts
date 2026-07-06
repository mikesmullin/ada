#!/usr/bin/env node
import * as path from "path";
import * as crypto from "crypto";
import { readFileSync, writeFileSync, unlinkSync } from "fs";
import express from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { BrowserAPI } from "./browser-api";

// Load mcp-server/.env (sibling of dist/) so EXTENSION_SECRET doesn't have to
// be exported by hand. Optional: env vars set by the caller still win, and a
// missing .env file (e.g. real deployments using actual env vars) is fine.
try {
  process.loadEnvFile(path.join(__dirname, "..", ".env"));
} catch {}

// Single-instance lock, same pidfile + kill(pid, 0) liveness-check pattern
// as ada-back.coffee's acquireInstanceLock/releaseInstanceLock -- lets any
// other process (ada-back's mcp-zen.coffee) deterministically tell whether
// an mcp-zen instance is already running without touching the network, and
// self-heals a stale lock left by a crash.
const LOCK_PATH = process.env.MCP_ZEN_LOCK || `${process.env.XDG_RUNTIME_DIR || "/tmp"}/mcp-zen.lock`;

function acquireLock() {
  try {
    const pid = Number(readFileSync(LOCK_PATH, "utf8").trim());
    if (pid && pid !== process.pid) {
      try {
        process.kill(pid, 0); // throws if not running
        console.error(`mcp-zen: already running (pid ${pid}, lock: ${LOCK_PATH})`);
        process.exit(1);
      } catch {
        // stale lock from a dead process -- take over
      }
    }
  } catch {
    // no lock file
  }
  writeFileSync(LOCK_PATH, `${process.pid}\n`);
}

function releaseLock() {
  try {
    if (Number(readFileSync(LOCK_PATH, "utf8").trim()) === process.pid) unlinkSync(LOCK_PATH);
  } catch {
    // already gone
  }
}

acquireLock();
process.on("exit", releaseLock);
function createMcpServer(): McpServer {
  const mcpServer = new McpServer({
    name: "mcp-zen",
    version: "0.1.0",
  });
  
  function text(str: string) {
    return { content: [{ type: "text" as const, text: str }] };
  }
  
  mcpServer.tool(
    "zen_list_tabs",
    "List all open tabs in the browser with their IDs, URLs, and titles",
    {},
    async () => {
      const tabs = await browserApi.listTabs();
      return text(JSON.stringify(tabs, null, 2));
    }
  );
  
  mcpServer.tool(
    "zen_navigate",
    "Navigate a tab to a URL (defaults to the active tab)",
    { url: z.string(), tabId: z.number().optional() },
    async ({ url, tabId }) => {
      const result = await browserApi.navigate(url, tabId);
      return text(`Navigated tab ${result.tabId} to ${result.url}`);
    }
  );
  
  mcpServer.tool(
    "zen_new_tab",
    "Open a new tab, optionally navigating to a URL",
    { url: z.string().optional() },
    async ({ url }) => {
      const tabId = await browserApi.newTab(url);
      return text(`New tab created: ${tabId}` + (url ? ` at ${url}` : ""));
    }
  );
  
  mcpServer.tool(
    "zen_close_tab",
    "Close a tab by ID",
    { tabId: z.number() },
    async ({ tabId }) => {
      await browserApi.closeTab(tabId);
      return text(`Closed tab ${tabId}`);
    }
  );
  
  mcpServer.tool(
    "zen_activate_tab",
    "Bring a tab to the foreground (also required before zen_screenshot, which can only capture the visible tab)",
    { tabId: z.number() },
    async ({ tabId }) => {
      await browserApi.activateTab(tabId);
      return text(`Activated tab ${tabId}`);
    }
  );
  
  mcpServer.tool(
    "zen_snapshot",
    'Get a structured snapshot of visible page elements with CSS selectors. Filter: "all", "interactive", or "form".',
    {
      tabId: z.number().optional(),
      filter: z.enum(["all", "interactive", "form"]).optional(),
      selector: z.string().optional(),
    },
    async ({ tabId, filter, selector }) => {
      const result = await browserApi.snapshot(tabId, filter, selector);
      return text(JSON.stringify(result, null, 2));
    }
  );
  
  mcpServer.tool(
    "zen_screenshot",
    "Take a screenshot of a tab. The tab is activated first since captureVisibleTab only works on the focused tab.",
    { tabId: z.number().optional() },
    async ({ tabId }) => {
      const dataUrl = await browserApi.screenshot(tabId);
      const base64 = dataUrl.replace(/^data:image\/png;base64,/, "");
      return { content: [{ type: "image" as const, data: base64, mimeType: "image/png" }] };
    }
  );
  
  mcpServer.tool(
    "zen_get_page_text",
    "Get the page title, URL, and visible text content. Useful for quickly understanding what is on the page.",
    { tabId: z.number().optional(), maxLength: z.number().optional() },
    async ({ tabId, maxLength }) => {
      const result = await browserApi.getPageText(tabId, maxLength);
      return text(JSON.stringify(result, null, 2));
    }
  );
  
  mcpServer.tool(
    "zen_get_form_fields",
    "List all form fields on the page with names, types, labels, current values, and CSS selectors",
    { tabId: z.number().optional() },
    async ({ tabId }) => {
      const fields = await browserApi.getFormFields(tabId);
      return text(JSON.stringify(fields, null, 2));
    }
  );
  
  mcpServer.tool(
    "zen_click",
    "Click an element by CSS selector",
    { selector: z.string(), tabId: z.number().optional() },
    async ({ selector, tabId }) => {
      const clicked = await browserApi.click(selector, tabId);
      return text(`Clicked ${clicked}`);
    }
  );
  
  mcpServer.tool(
    "zen_fill",
    "Fill a text input or textarea with a value. Clears existing content first. Dispatches input/change events for framework compatibility.",
    { selector: z.string(), value: z.string(), tabId: z.number().optional() },
    async ({ selector, value, tabId }) => {
      const filled = await browserApi.fill(selector, value, tabId);
      return text(`Filled ${selector}: ${filled}`);
    }
  );
  
  mcpServer.tool(
    "zen_select_option",
    "Select an option in a <select> dropdown by value or text",
    { selector: z.string(), value: z.string(), tabId: z.number().optional() },
    async ({ selector, value, tabId }) => {
      const result = await browserApi.selectOption(selector, value, tabId);
      return text(`Selected ${result.selected} (${result.text})`);
    }
  );
  
  mcpServer.tool(
    "zen_check",
    "Check/uncheck a checkbox or select a radio button",
    {
      selector: z.string(),
      checked: z.boolean().optional(),
      tabId: z.number().optional(),
    },
    async ({ selector, checked, tabId }) => {
      const result = await browserApi.check(selector, checked, tabId);
      return text(`${selector} checked=${result}`);
    }
  );
  
  mcpServer.tool(
    "zen_fill_form",
    "Fill multiple form fields at once. Each field specifies selector, value, and action (fill/select/check/uncheck/click).",
    {
      fields: z.array(
        z.object({
          selector: z.string(),
          value: z.string().optional(),
          action: z.enum(["fill", "select", "check", "uncheck", "click"]).optional(),
        })
      ),
      tabId: z.number().optional(),
    },
    async ({ fields, tabId }) => {
      const results = await browserApi.fillForm(fields, tabId);
      return text(JSON.stringify(results, null, 2));
    }
  );
  
  mcpServer.tool(
    "zen_scroll",
    "Scroll the page or scroll an element into view",
    {
      direction: z.enum(["up", "down", "top", "bottom"]).optional(),
      amount: z.number().optional(),
      selector: z.string().optional(),
      tabId: z.number().optional(),
    },
    async ({ direction, amount, selector, tabId }) => {
      const message = await browserApi.scroll(direction, amount, selector, tabId);
      return text(message);
    }
  );
  
  mcpServer.tool(
    "zen_press_key",
    'Send a synthetic keyboard event to the page: "Enter", "Tab", "Escape", "Backspace", "ArrowDown", etc, ' +
      "optionally with modifiers. Dispatches keydown/keyup only (no OS-level key injection), so native browser " +
      "behaviors driven by real key presses (e.g. Enter submitting a form) may not fire — prefer zen_click on the " +
      "submit button when that matters.",
    {
      key: z.string(),
      modifiers: z.array(z.enum(["ctrl", "shift", "alt", "meta"])).optional(),
      tabId: z.number().optional(),
    },
    async ({ key, modifiers, tabId }) => {
      const message = await browserApi.pressKey(key, modifiers, tabId);
      return text(message);
    }
  );
  
  mcpServer.tool(
    "zen_evaluate",
    "Execute JavaScript in the page and return the result",
    { script: z.string(), tabId: z.number().optional() },
    async ({ script, tabId }) => {
      const result = await browserApi.evaluate(script, tabId);
      return text(JSON.stringify(result, null, 2));
    }
  );
  
  mcpServer.tool(
    "zen_wait",
    "Wait for a specified number of milliseconds",
    { ms: z.number().optional() },
    async ({ ms }) => {
      const delay = ms ?? 1000;
      await new Promise((resolve) => setTimeout(resolve, delay));
      return text(`Waited ${delay}ms`);
    }
  );
  
  mcpServer.tool(
    "zen_wait_for",
    "Wait for text to appear on the page, or for a CSS selector to match an element. Returns when found or after timeout.",
    {
      text: z.string().optional(),
      selector: z.string().optional(),
      timeout: z.number().optional(),
      tabId: z.number().optional(),
    },
    async ({ text: searchText, selector, timeout, tabId }) => {
      const result = await browserApi.waitFor(searchText, selector, timeout, tabId);
      const what = searchText ? `text "${searchText}"` : `selector "${selector}"`;
      return text(
        result.found
          ? `Found ${what} after ${result.elapsedMs}ms`
          : `Timeout after ${result.elapsedMs}ms: ${what} not found`
      );
    }
  );
  return mcpServer;
}

const browserApi = new BrowserAPI();
browserApi.init().catch((err) => {
  console.error("mcp-zen: browser API init error", err);
  process.exit(1);
});

// Streamable HTTP transport, stateful mode: one session (and one McpServer
// instance -- a Server can only ever be connected to a single transport) per
// connected MCP client (ada-back, Claude Desktop, ad hoc scripts, ...). All
// sessions share the same browserApi, and thus the same persistent WebSocket
// connection to the extension, which stays up independent of any single
// client's session lifecycle.
const transports: Record<string, StreamableHTTPServerTransport> = {};

const app = express();
app.use(express.json());

app.post("/mcp", async (req, res) => {
  const sessionId = req.headers["mcp-session-id"] as string | undefined;
  let transport: StreamableHTTPServerTransport;

  if (sessionId && transports[sessionId]) {
    transport = transports[sessionId];
  } else if (!sessionId && isInitializeRequest(req.body)) {
    transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: () => crypto.randomUUID(),
      onsessioninitialized: (sid) => {
        transports[sid] = transport;
      },
    });
    transport.onclose = () => {
      if (transport.sessionId) delete transports[transport.sessionId];
    };
    await createMcpServer().connect(transport);
  } else {
    res.status(400).json({
      jsonrpc: "2.0",
      error: { code: -32000, message: "Bad Request: no valid session ID provided" },
      id: null,
    });
    return;
  }

  await transport.handleRequest(req, res, req.body);
});

const handleSessionRequest = async (req: express.Request, res: express.Response) => {
  const sessionId = req.headers["mcp-session-id"] as string | undefined;
  if (!sessionId || !transports[sessionId]) {
    res.status(400).send("Invalid or missing session ID");
    return;
  }
  await transports[sessionId].handleRequest(req, res);
};
app.get("/mcp", handleSessionRequest);
app.delete("/mcp", handleSessionRequest);

const HTTP_PORT = process.env.MCP_HTTP_PORT ? parseInt(process.env.MCP_HTTP_PORT, 10) : 8791;
const HTTP_HOST = process.env.CONTAINERIZED ? "0.0.0.0" : "localhost";
const httpServer = app.listen(HTTP_PORT, HTTP_HOST, () => {
  console.error(`mcp-zen: MCP HTTP server listening on http://${HTTP_HOST}:${HTTP_PORT}/mcp`);
});

function shutdown() {
  browserApi.close();
  httpServer.close();
  process.exit(0);
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
