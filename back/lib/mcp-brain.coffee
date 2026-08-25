# Bridges brain's MCP tools into agl-ai: one agent.Tool per brain tool,
# prefixed brain_* so they don't collide with other Ada tools.
#
# `brain mcp` is a thin stdio adapter over `brain server` (pglite owner).
# The MCP adapter auto-starts the server on connect and on each tool call
# if it is down. Ada still warms it here so the first turn is not a stall.
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'
import { spawn as spawnProcess } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import yaml from 'js-yaml'

client = null
tools = []
started = false
serverProc = null

ADA_ALIAS = process.env.ADA_BRAIN_ALIAS or 'ada'
BRAINS_CONFIG_PATH = join(homedir(), '.config', 'brain', 'brains.yaml')
START_TIMEOUT_MS = Number(process.env.ADA_BRAIN_SERVER_TIMEOUT_MS or 30000)
POLL_MS = 200

extractText = (result) ->
  if result?.isError
    parts = (result.content or []).map (c) -> if c.type is 'text' then c.text else "[#{c.type}]"
    return "brain error: #{parts.join('\n') or 'unknown error'}"
  parts = (result.content or []).map (c) -> if c.type is 'text' then c.text else "[#{c.type}]"
  parts.join('\n') or '(no output)'

schemaProps = (inputSchema) ->
  inputSchema?.properties or {}

schemaRequired = (inputSchema) ->
  inputSchema?.required or []

sleep = (ms) -> new Promise (resolve) -> setTimeout resolve, ms

# Same path rules as mstack/brain `brain use`: alias → project root (parent of db/).
resolveAliasPath = (value) ->
  path = String(value).trim().replace(/^~(?=\/|$)/, homedir())
  if isAbsolute(path) then path else resolve(dirname(BRAINS_CONFIG_PATH), path)

loadBrainsConfig = ->
  return {} unless existsSync(BRAINS_CONFIG_PATH)
  raw = yaml.load(readFileSync(BRAINS_CONFIG_PATH, 'utf8')) or {}
  unless raw? and typeof raw is 'object' and not Array.isArray(raw) then {} else raw

# Prefer the named `brain use` alias (default: ada). Fallback: opts / env / cwd db/.
export resolveAdaBrain = (opts = {}) ->
  alias = opts.alias or ADA_ALIAS
  brains = loadBrainsConfig()
  if typeof brains[alias] is 'string'
    cwd = resolveAliasPath(brains[alias])
    return { alias, cwd, root: join(cwd, 'db') }
  cwd = opts.cwd or process.env.ADA_BRAIN_CWD or new URL('../../', import.meta.url).pathname
  cwd = cwd.replace(/\/$/, '')
  root = opts.root or process.env.BRAIN_ROOT or process.env.ADA_BRAIN or "#{cwd}/db"
  { alias: null, cwd, root }

pidAlive = (pid) ->
  try
    process.kill pid, 0
    true
  catch
    false

# Live PID + sock (a leftover .sock after a crash is not "running").
isBrainServerRunning = (root) ->
  sock = join root, '.sock'
  lockFile = join root, '.lock'
  return false unless existsSync(sock) and existsSync(lockFile)
  try
    pid = JSON.parse(readFileSync(lockFile, 'utf8')).pid
    pid and pidAlive(pid)
  catch
    false

# Pin this child to an alias via `brain --use` so a later `brain use` in
# another shell cannot retarget Ada's server/mcp. Does not persist.
brainCliArgs = (alias, rest) ->
  if alias then ['--use', alias, rest...] else rest

childEnv = (root, alias) ->
  env = Object.assign {}, process.env
  if alias
    # --use is the pin; a leftover BRAIN_ROOT must not override it.
    delete env.BRAIN_ROOT
  else
    env.BRAIN_ROOT = root
  env

# Long-running pglite owner. Detached so a later ada-back restart can reuse it.
startBrainServer = (brainCmd, cwd, root, alias, env) ->
  args = brainCliArgs alias, ['server', 'start']
  console.error "brain server: not running for #{root}, starting (#{brainCmd} #{args.join ' '})..."
  child = spawnProcess brainCmd, args,
    cwd: cwd
    env: env
    detached: true
    stdio: ['ignore', 'pipe', 'pipe']
  serverProc = child
  prefix = (buf) ->
    for line in String(buf).split(/\r?\n/) when line.trim()
      console.error "brain server: #{line}"
  child.stdout?.on 'data', prefix
  child.stderr?.on 'data', prefix
  child.on 'error', (e) ->
    console.error "brain server: failed to spawn (#{e.message})"
  child.on 'exit', (code, signal) ->
    # Exit 1 is also "already running" — treat missing sock as the real failure.
    unless isBrainServerRunning(root)
      console.error "brain server: exited code=#{code} signal=#{signal or ''} (no sock at #{root}/.sock)"
    if serverProc is child
      serverProc = null
  child.unref()

waitForBrainServer = (root, timeoutMs) ->
  deadline = Date.now() + timeoutMs
  until isBrainServerRunning(root)
    return false if Date.now() > deadline
    await sleep POLL_MS
  true

# Call a raw brain MCP tool by unprefixed name (put_entity, get_entity, …).
export callBrainTool = (name, args = {}) ->
  unless client
    throw new Error 'brain mcp not connected'
  # Ada updates existing notes often; default overwrite so put_entity is not a no-op.
  if name is 'put_entity' and args.overwrite is undefined
    args = Object.assign {}, args, overwrite: true
  # Voice path has no copilot token; keyword search works against the live index.
  if name is 'search' and args.strategy is undefined
    args = Object.assign {}, args, strategy: 'keyword'
  extractText await client.callTool name: name, arguments: args

connectBrainMcp = (brainCmd, cwd, root, alias, env) ->
  transport = new StdioClientTransport
    command: brainCmd
    args: brainCliArgs alias, ['mcp']
    cwd: cwd
    env: env
    stderr: 'pipe'
  transport.stderr?.on 'data', (buf) ->
    for line in String(buf).split(/\r?\n/) when line.trim()
      console.error "brain mcp: #{line}"
  c = new Client name: 'ada-back', version: '0.1.0'
  await c.connect transport
  { tools: discovered } = await c.listTools()
  client = c
  tools = discovered or []
  started = true
  pin = if alias then "--use #{alias}" else "BRAIN_ROOT=#{root}"
  console.error "brain mcp: #{tools.length} tools (#{pin} root=#{root})"
  true

export ensureBrainMcp = (opts = {}) ->
  { cwd, root, alias } = resolveAdaBrain(opts)
  return true if client and tools.length and isBrainServerRunning(root)

  brainCmd = opts.command or process.env.ADA_BRAIN_CMD or 'brain'
  env = childEnv root, alias

  unless existsSync(root)
    console.error "brain mcp: no db at #{root} (alias=#{alias or 'none'})"
    return false

  try
    unless isBrainServerRunning(root)
      startBrainServer brainCmd, cwd, root, alias, env
      unless await waitForBrainServer(root, START_TIMEOUT_MS)
        console.error "brain mcp: brain server did not become ready within #{START_TIMEOUT_MS}ms (#{root}/.sock)"
        return false
      console.error "brain server: ready (#{root}/.sock)"

    await connectBrainMcp brainCmd, cwd, root, alias, env
    true
  catch e
    client = null
    tools = []
    started = false
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
          'Writes always persist even if schema-invalid; if the tool returns valid:false ' +
          'or a validation notice, the record is on disk — try a corrected overwrite when you can. ' +
          'Only say you remembered after this tool reports a saved path (not a hard error).'
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
      else if /valid:\s*false|considered INVALID/i.test(out)
        # Soft schema issues — still persisted; surface so the agent can fix up.
        "ok: saved #{id} — #{text}\n#{out}"
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
      chunks = []
      primary = await callBrainTool 'search', { query: q, limit: 5 }
      chunks.push primary
      # Keyword FTS is AND; a long phrase can miss when any one token is absent.
      if searchLooksEmpty(primary)
        for token in q.split(/\s+/).filter((w) -> w.length > 2)
          hit = await callBrainTool 'search', { query: token, limit: 4 }
          chunks.push "# token #{token}\n#{hit}" unless searchLooksEmpty(hit)
      # "family" is not a stored token; household notes say kids / wife / Smullin.
      if /famil|household|people|who.*(know|related)/i.test(q)
        for token in ['Smullin', 'kids', 'wife']
          hit = await callBrainTool 'search', { query: token, limit: 5 }
          chunks.push "# household #{token}\n#{hit}" unless searchLooksEmpty(hit)
      # Deterministic fallback for the well-known preference slug when search is empty
      # or only returns ghosts (should be rare after brain index sync).
      if /favorite\s+colou?r|favou?rite\s+colou?r/i.test(q)
        try
          direct = await callBrainTool 'get_entity', { slug: 'Note/favorite-color' }
          unless direct.startsWith 'brain error'
            chunks.push "# direct get Note/favorite-color\n#{direct}"
      chunks.join '\n\n'
    catch e
      "brain error: #{e.message}"

export brainToolNames = ->
  names = for t in tools
    if t.name.startsWith('brain_') then t.name else "brain_#{t.name}"
  names.concat ['remember_fact', 'recall_search']

searchLooksEmpty = (text) ->
  s = String(text or '').trim()
  return true if not s or s is '[]' or s is 'results: []'
  /brain error:/i.test(s)

# Note/favorite-color style id from free text
defaultNoteSlug = (fact) ->
  s = fact.toLowerCase()
  # common preference patterns
  if /favorite\s+colou?r/.test(s) then return 'favorite-color'
  if /favou?rite\s+colou?r/.test(s) then return 'favorite-color'
  slug = s.replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 48)
  slug or "fact-#{Date.now().toString(36)}"
