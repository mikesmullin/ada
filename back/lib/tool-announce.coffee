# Pre-tool announce: short spoken status before a tool body runs.
# Instant tools use a deterministic phrase (no LLM). Others try a microagent
# with a hard timeout so a slow model never hangs the tool gate.
import Agent from 'agl-ai'

SYSTEM = '''
You write a single short spoken status line for a voice assistant that is
about to run a tool. The line is read aloud immediately, so:

- One short phrase only (about 3–8 words). Prefer progressive/participial
  form: "running the mock slow tool", "checking your task list",
  "saving that to memory", "looking that up".
- No greeting, no name ("Mike"), no "for you", "now", "I'll", "let me",
  "certainly", "sure". Not a full sentence with a subject if a fragment works.
- No markdown, quotes, or trailing period required.
- Do not invent tools or reasons beyond the given tool name and arguments.
- If the tool name is opaque, plain-language it (e.g. mock_slow_tool →
  "mock slow tool", todo_next → "checking your task list").
'''

# Skip LLM for these — they finish in ms; waiting on Gemma would feel like a hang.
FAST_TOOLS = new Set [
  'current_time'
  'desk_light'
  'pc_light_color'
  'media_control'
  'todo_lists'
  'todo_next'
  'todo_tree'
  'todo_view'
  'todo_take'
  'todo_release'
  'todo_upsert'
  'recall_search'
  'brain_search'
  'brain_get_entity'
  'brain_graphql'
  'brain_graph'
  'brain_schema_methods'
]

# Cap microagent latency; on timeout use deterministic fallback.
ANNOUNCE_TIMEOUT_MS = 2000

export fallbackAnnounce = (toolName, args = {}) ->
  switch toolName
    when 'mock_slow_tool' then 'running the mock slow tool'
    when 'control_browser' then 'using the browser'
    when 'remember_fact', 'brain_put_entity' then 'saving that to memory'
    when 'recall_search', 'brain_search', 'brain_get_entity', 'brain_think' then 'checking memory'
    when 'todo_next', 'todo_tree', 'todo_view', 'todo_lists' then 'checking your task list'
    when 'todo_upsert', 'todo_take', 'todo_release' then 'updating a task'
    when 'desk_light', 'pc_light_color' then 'adjusting the lights'
    when 'media_control' then 'controlling media'
    when 'run_application' then "launching #{args.app or 'an app'}"
    when 'run_activity_command' then "running #{args.id or 'an activity'}"
    when 'current_time' then 'checking the time'
    else
      human = String(toolName or 'a tool').replace /_/g, ' '
      "running #{human}"

cleanLine = (line, fallback) ->
  line = String(line or '').replace(/[\t\n]+/g, ' ').trim()
  line = line.replace /^["']|["']$/g, ''
  line = line.replace /\.+$/, ''
  if not line or line.length > 120 then fallback else line

runMicroagent = (toolName, args, model) ->
  speech = null
  agent = await Agent.factory
    model: model
    max_tokens: 48
    tool_choice: 'required'
    system_prompt: SYSTEM
    output_tool:
      name: 'announce'
      description: 'Emit the short spoken status line for the tool about to run.'
      parameters:
        speech:
          type: 'string'
          description: 'Succinct progressive phrase, e.g. "running the mock slow tool". No names, no filler.'
      required: ['speech']
      fn: (ctx, { speech: s }) ->
        speech = String(s or '').replace(/[\t\n]+/g, ' ').trim()
        speech

  argJson = try JSON.stringify(args or {}) catch e then '{}'
  if argJson.length > 400
    argJson = argJson.slice(0, 400) + '…'

  await agent.run
    prompt: """
      <tool-name>#{toolName}</tool-name>
      <tool-args>#{argJson}</tool-args>
      Produce the announce speech via the announce tool.
      """

  speech or agent.last_output?.speech or agent.last_output

export announceTool = ({ toolName, args, model, log, timeoutMs }) ->
  fallback = fallbackAnnounce toolName, args or {}

  # Instant tools: never call the LLM (avoids multi-second hangs on "what time is it?").
  if FAST_TOOLS.has(toolName) or not model
    log? "announce (fast): #{fallback}"
    return fallback

  limit = timeoutMs ? ANNOUNCE_TIMEOUT_MS
  try
    timedOut = false
    line = await Promise.race [
      Promise.resolve().then(-> runMicroagent toolName, args, model)
      new Promise (resolve) ->
        setTimeout ->
          timedOut = true
          resolve null
        , limit
    ]
    if timedOut or line is null
      log? "announce timeout #{limit}ms, fallback: #{fallback}"
      return fallback
    out = cleanLine line, fallback
    log? "announce: #{out}"
    out
  catch e
    log? "announce failed (#{e.message}), fallback: #{fallback}"
    fallback
