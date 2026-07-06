# Bridges mcp-zen's zen_* browser-control tools into agl-ai 1:1: one
# agent.Tool() per tool the mcp-zen server exposes. ensureMcpZen deterministically
# checks (and starts, if needed) the mcp-zen server before every browser-agent
# call -- not just once at startup -- so a never-started or crashed mcp-zen
# self-heals on the next browser task instead of being permanently disabled
# for the rest of ada-back's process life.
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { spawn as spawnProcess } from 'node:child_process'
import { readFileSync } from 'node:fs'

MCP_ZEN_URL = process.env.MCP_ZEN_URL or 'http://localhost:8791/mcp'

# Same pidfile + kill(pid, 0) liveness-check pattern as ada-back.coffee's own
# acquireInstanceLock/releaseInstanceLock, checked against the lock mcp-zen's
# server.ts writes on startup (same default path on that side).
LOCK_PATH = process.env.MCP_ZEN_LOCK or "#{process.env.XDG_RUNTIME_DIR or '/tmp'}/mcp-zen.lock"
START_TIMEOUT_MS = 15000
POLL_INTERVAL_MS = 500

client = null
tools = []

extractText = (result) ->
  parts = (result.content or []).map (c) -> if c.type is 'text' then c.text else "[#{c.type}]"
  parts.join('\n') or '(no output)'

isMcpZenRunning = ->
  try
    pid = Number readFileSync(LOCK_PATH, 'utf8').trim()
    return false unless pid
    process.kill pid, 0 # throws if not running
    true
  catch e
    false

startMcpZenProcess = ->
  console.error 'mcp-zen: not running, starting it...'
  try
    child = spawnProcess 'mcp-zen', [], detached: true, stdio: 'ignore'
    child.unref()
  catch e
    console.error "mcp-zen: failed to spawn (#{e.message})"

# Connects and discovers the tool list. Internal -- callers go through
# ensureMcpZen, which decides whether this (and starting the process first)
# is actually necessary.
connectMcpZen = ->
  try
    transport = new StreamableHTTPClientTransport(new URL(MCP_ZEN_URL))
    c = new Client name: 'ada-back', version: '0.1.0'
    await c.connect transport
    { tools: discovered } = await c.listTools()
    client = c
    tools = discovered
    console.error "mcp-zen: #{tools.length} browser tools available (#{MCP_ZEN_URL})"
    true
  catch e
    client = null
    tools = []
    console.error "mcp-zen: connect failed (#{e.message})"
    false

# Deterministically ensures mcp-zen is running (starting it via the `mcp-zen`
# command on $PATH if the lock file shows no live pid) and that we're
# connected to it, before any browser-agent tool call proceeds.
export ensureMcpZen = ->
  unless isMcpZenRunning()
    startMcpZenProcess()
    deadline = Date.now() + START_TIMEOUT_MS
    until isMcpZenRunning()
      if Date.now() > deadline
        console.error "mcp-zen: did not start within #{START_TIMEOUT_MS}ms"
        return false
      await new Promise (resolve) -> setTimeout resolve, POLL_INTERVAL_MS

  return true if client and tools.length # already connected to the running instance
  await connectMcpZen()

export registerMcpZenTools = (agent) ->
  for tool in tools
    do (tool) ->
      agent.Tool tool.name, tool.description or '',
        tool.inputSchema?.properties or {},
        tool.inputSchema?.required or [],
        (ctx, args) ->
          try
            extractText await client.callTool name: tool.name, arguments: args
          catch e
            # clear cached state so the next ensureMcpZen() call re-checks
            # liveness and reconnects, instead of assuming this stale
            # client/tools pair is still good.
            client = null
            tools = []
            "mcp-zen error: #{e.message}"
