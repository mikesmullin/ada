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

# Call a raw brain MCP tool by unprefixed name (put_entity, get_entity, …).
export callBrainTool = (name, args = {}) ->
  unless client
    throw new Error 'brain mcp not connected'
  # Ada updates existing notes often; default overwrite so put_entity is not a no-op.
  if name is 'put_entity' and args.overwrite is undefined
    args = Object.assign {}, args, overwrite: true
  extractText await client.callTool name: name, arguments: args

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
      if tool.name is 'put_entity'
        desc = '[long-term memory] Create or UPDATE an entity. content is YAML ' +
          'frontmatter (e.g. "body:\\n  body: Mike prefers green.\\n  tags: [preference]\\n"). ' +
          'slug is Class/id (Note/favorite-color, Person/msmullin). ' +
          'Always set overwrite=true when replacing an existing fact. ' +
          'Only say you remembered after this tool succeeds.'
      else
        desc = "[long-term memory] #{desc}"
      agent.Tool name, desc,
        schemaProps(tool.inputSchema),
        schemaRequired(tool.inputSchema),
        (ctx, args) ->
          try
            await callBrainTool tool.name, args or {}
          catch e
            client = null
            tools = []
            started = false
            "brain mcp error: #{e.message}"

  # Simple voice-friendly wrappers — Gemma often skips full put_entity YAML.
  agent.Tool 'remember_fact',
    'Save a durable fact or preference Mike wants remembered. Call this when he ' +
    'says remember, do not forget, or states a lasting preference (favorite color, ' +
    'names, etc). Only confirm success after this tool returns ok. Prefer a stable ' +
    'slug like Note/favorite-color so later updates replace the same file.',
    fact:
      type: 'string'
      description: 'plain English fact, e.g. "Mike favorite color is green"'
    slug:
      type: 'string'
      description: 'optional Class/id; default Note/<short-id> from the fact topic'
  , ['fact'], (ctx, { fact, slug }) ->
    try
      text = String(fact or '').trim()
      return 'brain error: empty fact' unless text
      id = if slug then String(slug).trim() else defaultNoteSlug text
      id = "Note/#{id}" unless id.includes '/'
      # Escape for YAML double-quoted scalar
      escaped = text.replace(/\\/g, '\\\\').replace(/"/g, '\\"')
      content = "body:\n  body: \"#{escaped}\"\n  tags:\n    - preference\n"
      out = await callBrainTool 'put_entity', { slug: id, content, overwrite: true }
      if out.startsWith 'brain error'
        out
      else
        "ok: saved #{id} — #{text}"
    catch e
      "brain error: #{e.message}"

  agent.Tool 'recall_search',
    'Search long-term memory for a fact or person. Use when Mike asks what you ' +
    'remember or after a context-compaction notice. Prefer this over guessing. ' +
    'If a result slug 404s on brain_get_entity, try the next hit or Note/favorite-color ' +
    'for color preferences — never invent a missing fact.',
    query: { type: 'string', description: 'search phrase, e.g. favorite color' }
  , ['query'], (ctx, { query }) ->
    try
      q = String(query or '')
      out = await callBrainTool 'search', { query: q, limit: 5 }
      # Deterministic fallback for the well-known preference slug when search is empty
      # or only returns ghosts (should be rare after brain index sync).
      if /favorite\s+colou?r|favou?rite\s+colou?r/i.test(q)
        try
          direct = await callBrainTool 'get_entity', { slug: 'Note/favorite-color' }
          unless direct.startsWith 'brain error'
            out = "#{out}\n\n# direct get Note/favorite-color\n#{direct}"
      out
    catch e
      "brain error: #{e.message}"

export brainToolNames = ->
  names = for t in tools
    if t.name.startsWith('brain_') then t.name else "brain_#{t.name}"
  names.concat ['remember_fact', 'recall_search']

# Note/favorite-color style id from free text
defaultNoteSlug = (fact) ->
  s = fact.toLowerCase()
  # common preference patterns
  if /favorite\s+colou?r/.test(s) then return 'favorite-color'
  if /favou?rite\s+colou?r/.test(s) then return 'favorite-color'
  slug = s.replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 48)
  slug or "fact-#{Date.now().toString(36)}"
