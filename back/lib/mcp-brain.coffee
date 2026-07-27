# Bridges brain's MCP tools into agl-ai: one agent.Tool per brain tool,
# prefixed brain_* so they don't collide with other Ada tools.
# Spawns `brain mcp` over stdio with cwd/BRAIN_ROOT pointing at Ada's private db.
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'

client = null
tools = []
started = false

extractText = (result) ->
  if result?.isError
    parts = (result.content or []).map (c) -> if c.type is 'text' then c.text else "[#{c.type}]"
    return "brain error: #{parts.join('\n') or 'unknown error'}"
  parts = (result.content or []).map (c) -> if c.type is 'text' then c.text else "[#{c.type}]"
  parts.join('\n') or '(no output)'

# jsonSchema properties → agl-ai Tool param map (pass through; empty if none)
schemaProps = (inputSchema) ->
  inputSchema?.properties or {}

schemaRequired = (inputSchema) ->
  inputSchema?.required or []

export ensureBrainMcp = (opts = {}) ->
  return true if client and tools.length

  brainCmd = opts.command or process.env.ADA_BRAIN_CMD or 'brain'
  brainCwd = opts.cwd or process.env.ADA_BRAIN_CWD or new URL('../../', import.meta.url).pathname
  brainRoot = opts.root or process.env.BRAIN_ROOT or process.env.ADA_BRAIN or "#{brainCwd.replace(/\/$/, '')}/db"

  try
    # Inherit a safe env subset + full PATH, force BRAIN_ROOT for this process tree.
    env = Object.assign {}, process.env,
      BRAIN_ROOT: brainRoot
    transport = new StdioClientTransport
      command: brainCmd
      args: ['mcp']
      cwd: brainCwd
      env: env
      stderr: 'pipe'
    c = new Client name: 'ada-back', version: '0.1.0'
    await c.connect transport
    { tools: discovered } = await c.listTools()
    client = c
    tools = discovered or []
    started = true
    console.error "brain mcp: #{tools.length} tools (BRAIN_ROOT=#{brainRoot})"
    true
  catch e
    client = null
    tools = []
    console.error "brain mcp: connect failed (#{e.message})"
    false

export registerBrainTools = (agent) ->
  return unless client and tools.length
  for tool in tools
    do (tool) ->
      # Prefix avoids clashing with future Ada-native tools named search/think/etc.
      name = if tool.name.startsWith('brain_') then tool.name else "brain_#{tool.name}"
      desc = tool.description or "brain #{tool.name}"
      desc = "[long-term memory] #{desc}"
      agent.Tool name, desc,
        schemaProps(tool.inputSchema),
        schemaRequired(tool.inputSchema),
        (ctx, args) ->
          try
            extractText await client.callTool name: tool.name, arguments: args or {}
          catch e
            client = null
            tools = []
            started = false
            "brain mcp error: #{e.message}"

export brainToolNames = ->
  for t in tools
    if t.name.startsWith('brain_') then t.name else "brain_#{t.name}"
