# Pre-tool announce microagent (PLAN2-style): one decision — a short spoken
# status line for what tool is starting. Enqueued in Ada's voice before the
# tool body runs. Keep it terse; no "for you, Mike" / filler.
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

# Deterministic fallback if the microagent fails or is slow.
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

export announceTool = ({ toolName, args, model, log }) ->
  fallback = fallbackAnnounce toolName, args or {}
  unless model
    log? "announce fallback (no model): #{fallback}"
    return fallback

  try
    speech = null
    agent = await Agent.factory
      model: model
      max_tokens: 64
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

    line = speech or agent.last_output?.speech or agent.last_output
    line = String(line or '').replace(/[\t\n]+/g, ' ').trim()
    # Strip trailing punctuation and common filler if the model sneaks it in
    line = line.replace /^["']|["']$/g, ''
    line = line.replace /\.+$/, ''
    if not line or line.length > 120
      log? "announce fallback (bad model output): #{fallback}"
      return fallback
    log? "announce: #{line}"
    line
  catch e
    log? "announce failed (#{e.message}), fallback: #{fallback}"
    fallback
