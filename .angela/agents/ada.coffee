# Ada — voice companion. Production entrypoint is ada-back (Angela library).
# This file is the harness identity for `angela -a ada` / cowork.
#
# House MCP tools are unprefixed (prefix: false). Brain/todo keep server__ names.
# ada-back injects BASE+SOUL as system at runtime.

module.exports = (ctx) ->
  bun = process.execPath
  root = ctx.projectRoot or '/workspace/ada'
  name: 'ada'
  description: 'Always-on voice companion on the home PC'
  # model omitted — FAV_LOCAL_LLM / Angela default; ctx window from agl
  policyMode: 'ask'
  parallel_tools: true
  max_turns: Number(process.env.ADA_MAX_TURNS or 20)
  mcp: [
    {
      name: 'home'
      prefix: false
      command: bun
      args: ["#{root}/back/mcp/home/server.coffee"]
      cwd: "#{root}/back"
      env:
        ADA_ACTIVITY_DIR: process.env.ADA_ACTIVITY_DIR or '/workspace/mari/activity'
        ADA_VOICE_SOCK: process.env.ADA_VOICE_SOCK or
          "#{process.env.XDG_RUNTIME_DIR or '/tmp'}/ada-voice.sock"
    }
    {
      name: 'brain'
      command: process.env.ADA_BRAIN_CMD or 'brain'
      args: ['--use', 'ada', 'mcp']
      cwd: root
    }
    {
      name: 'todo'
      command: process.env.ADA_TODO_CMD or 'todo'
      args: ['mcp']
    }
  ]
