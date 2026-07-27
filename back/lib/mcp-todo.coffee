# Bridges upgraded `todo mcp` (tasks.md DSL) into agl-ai as todo_* tools.
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'

client = null
tools = []

extractText = (result) ->
  if result?.isError
    parts = (result.content or []).map (c) -> if c.type is 'text' then c.text else "[#{c.type}]"
    return "todo error: #{parts.join('\n') or 'unknown error'}"
  parts = (result.content or []).map (c) -> if c.type is 'text' then c.text else "[#{c.type}]"
  parts.join('\n') or '(no output)'

schemaProps = (inputSchema) -> inputSchema?.properties or {}
schemaRequired = (inputSchema) -> inputSchema?.required or []

export ensureTodoMcp = (opts = {}) ->
  return true if client and tools.length

  todoCmd = opts.command or process.env.ADA_TODO_CMD or 'todo'
  shared = opts.shared or process.env.TODO_SHARED or
    process.env.ADA_TASK_SHARED or '/workspace/Biz/EM/Agent/ada-shared.task.md'

  try
    env = Object.assign {}, process.env,
      TODO_SHARED: shared
      TODO_DEFAULT_LIST: 'shared'
    transport = new StdioClientTransport
      command: todoCmd
      args: ['mcp']
      env: env
      stderr: 'pipe'
    c = new Client name: 'ada-back', version: '0.1.0'
    await c.connect transport
    { tools: discovered } = await c.listTools()
    client = c
    tools = discovered or []
    console.error "todo mcp: #{tools.length} tools (shared=#{shared})"
    true
  catch e
    client = null
    tools = []
    console.error "todo mcp: connect failed (#{e.message})"
    false

export registerTodoTools = (agent) ->
  return unless client and tools.length
  for tool in tools
    do (tool) ->
      name = if tool.name.startsWith('todo_') then tool.name else "todo_#{tool.name}"
      desc = "[tasks] #{tool.description or tool.name}"
      agent.Tool name, desc,
        schemaProps(tool.inputSchema),
        schemaRequired(tool.inputSchema),
        (ctx, args) ->
          try
            extractText await client.callTool name: tool.name, arguments: args or {}
          catch e
            client = null
            tools = []
            "todo mcp error: #{e.message}"
