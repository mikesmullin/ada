# MCP Zen browser tools on Ada; external ada_prompt tools are NOT registered here.
import { BrowserBridge } from './browser-bridge.mjs'
import { browserResult } from './browser-result.mjs'

bridge = new BrowserBridge()

export ensureMcpZen = ->
  try
    await bridge.ensure()
  catch e
    console.error "mcp-zen: #{e.message}"
    false

export registerMcpZenTools = (agent, { policy } = {}) ->
  for tool in bridge.tools
    do (tool) ->
      agent.Tool tool.name, tool.description or '',
        tool.inputSchema?.properties or {},
        tool.inputSchema?.required or [],
        (ctx, args = {}) ->
          signal = ctx?.signal or agent._runAbort?.signal
          signal?.throwIfAborted()
          # Direct Agent.Tool registration does not automatically run Angela's
          # MCP policy wrapper. All browser tools must cross this boundary too.
          unless policy
            throw new Error 'Browser policy is unavailable; refusing the call'
          auth = await policy.authorize
            tool: tool.name
            server: 'mcp-zen'
            mcpTool: tool.name
            args: args
          unless auth.allowed
            throw new Error "Browser tool denied: #{tool.name}"
          signal?.throwIfAborted()
          result = await bridge.call tool.name, args, { signal }
          browserResult result, agent.model
      # Keep full schema/annotations for inspection and policy-aware consumers.
      # AGL currently exposes properties/required; MCP validates full schema.
      agent.tools[tool.name]._inputSchema = tool.inputSchema
      agent.tools[tool.name]._annotations = tool.annotations
