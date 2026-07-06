# mcp-zen

A persistent MCP HTTP server paired with a Zen/Firefox browser extension that
lets any MCP client (Claude Code, Claude Desktop, `ada-back`, or anything else
that speaks MCP) remote-control your **actual, already-running** browser:
navigate, read, click, fill forms, screenshot, run JS.

The server runs as one long-lived process (`mcp-zen`, installed on `$PATH`)
rather than being spawned per-client. This matters because the browser
extension's WebSocket connection to it is completely decoupled from any
individual MCP client's session lifecycle — the extension connects once and
stays connected for as long as the server runs, regardless of how many
short-lived MCP sessions come and go on top of it (each `mcpcall.mjs`
invocation, each `ada-back` restart, etc.).

It combines two ideas from other projects (see `git log` / commit history for
where this came from):

- The tool surface of [zen-mcp](https://github.com/sh6drack/zen-mcp), which
  talks to Zen over WebDriver BiDi. BiDi requires launching a dedicated
  browser instance with `--remote-debugging-port`, which doesn't work for a
  browser you're already using day-to-day.
- The architecture of
  [browser-control-mcp](https://github.com/eyalzh/browser-control-mcp): MCP
  server ↔ localhost WebSocket (HMAC-signed) ↔ a WebExtension background
  script that performs the actions. This is what lets it attach to your main
  browser window instead of a separate automation-only instance.

## Setup

### 1. Load the extension in Zen

1. Build it: `npm install && npm run build` (from this directory).
2. In Zen, open `about:debugging` → "This Firefox" → "Load Temporary
   Add-on..." → select `firefox-extension/manifest.json`.
3. The options page opens automatically. Copy the generated secret.
4. Click **Enable browser automation** on the options page. This grants the
   extension access to all sites (`<all_urls>`), which every page-interaction
   tool (`zen_click`, `zen_fill`, `zen_snapshot`, `zen_evaluate`,
   `zen_screenshot`, ...) needs. It's a one-time grant, revocable any time
   from `about:addons`.

> "Temporary" add-ons are unloaded when Zen restarts — you'll need to
> re-load `manifest.json` (and re-copy the secret only if you regenerate it)
> each time, unless you package and install it permanently.

### 2. Configure the secret

```bash
cd mcp-server
cp .env.example .env
# edit .env, paste the secret from the options page as EXTENSION_SECRET
```

`.env` is gitignored — the secret never gets committed. `server.ts` loads it
at startup (`mcp-server/.env`, sibling of `dist/`); explicit env vars set by
whatever launches the process still take priority over the file. `.env` also
sets `MCP_HTTP_PORT` (default `8791`) alongside `EXTENSION_PORT` (default
`8765`, the WebSocket port the extension connects to — a different port from
the one MCP clients talk to).

### 3. Install and run

```bash
ln -sf "$(pwd)/bin/mcp-zen" ~/.local/bin/mcp-zen   # once, so it's on $PATH
mcp-zen                                             # runs in the foreground
```

It prints both listening addresses on startup and then blocks — run it under
your process supervisor of choice (systemd user service, `nohup ... &`,
whatever fits) for a real persistent deployment.

Point any MCP client at `http://localhost:8791/mcp` (Streamable HTTP), e.g.
Claude Desktop:

```json
{
  "mcpServers": {
    "zen": { "url": "http://localhost:8791/mcp" }
  }
}
```

For quick ad hoc testing without a full MCP client, use `mcpcall.mjs`:

```bash
node mcpcall.mjs zen_list_tabs '{}'
node mcpcall.mjs zen_navigate '{"tabId":12,"url":"https://example.com"}'
```

Each invocation opens its own short-lived MCP session — cheap, since it's
independent of the extension's WebSocket connection.

## Tools

| Tool | Notes |
|---|---|
| `zen_list_tabs` | |
| `zen_navigate` | |
| `zen_new_tab` | |
| `zen_close_tab` | |
| `zen_activate_tab` | Bring a tab to the foreground |
| `zen_snapshot` | Structured elements + selectors (filter: all/interactive/form) |
| `zen_screenshot` | Activates the tab first — see limitation below |
| `zen_get_page_text` | |
| `zen_get_form_fields` | |
| `zen_click` | |
| `zen_fill` | Native setter + input/change events, works with React/Vue/Angular |
| `zen_select_option` | |
| `zen_check` | |
| `zen_fill_form` | Batch of `{selector, value, action}` |
| `zen_scroll` | |
| `zen_press_key` | Synthetic keydown/keyup — see limitation below |
| `zen_evaluate` | Arbitrary JS in the page |
| `zen_wait` | No browser round trip |
| `zen_wait_for` | Polls in-page for text or a selector |

Every tab-scoped tool takes an optional `tabId`; omit it to target the
active tab of the current window.

## Known limitations (vs. zen-mcp's BiDi approach)

- **Screenshots** only work on the visible/focused tab
  (`captureVisibleTab`), so `zen_screenshot` activates the target tab first.
  BiDi can capture background tabs; a WebExtension can't.
- **`zen_press_key`** dispatches synthetic `KeyboardEvent`s, not real OS-level
  key injection. Most JS listeners (`keydown` handlers, framework key
  bindings) work fine; native browser behaviors triggered by a *real*
  keypress (e.g. Enter submitting a form via the browser's built-in
  behavior) may not fire — use `zen_click` on the submit button instead when
  that matters.
- The extension only allows commands listed in
  `firefox-extension/allowed-tools.yaml`. There's no dynamic per-tool toggle
  UI or per-domain consent flow (deliberately, for simplicity) — edit that
  file and rebuild to change what's enabled.

## Notes

- `typescript` is pinned to `~5.7.3` in every `package.json`. TypeScript 5.8+
  has a regression (excessive/infinite type instantiation, `TS2589`, or an
  outright OOM crash on `tsc`) when compiling many chained
  `mcpServer.tool(...)` calls against zod schemas with the currently
  published `@modelcontextprotocol/sdk`. Confirmed by bisecting: 5.7.3 and
  earlier compile clean, 5.8.3+ fails. Worth re-checking whether upstream
  fixes this before bumping.

## Project layout

```
common/             shared TS message types (server <-> extension)
mcp-server/         persistent MCP HTTP server; hosts the WebSocket server the extension connects to
firefox-extension/  background script (WebSocket client) + options page
bin/mcp-zen         PATH-installable entry point (symlink ~/.local/bin/mcp-zen -> this)
mcpcall.mjs         one-off MCP tool call over HTTP, for ad hoc testing
```
