# Ada-only tools that are not part of mcp-home: listen (voice sock shim) and
# control_browser (mcp-zen sub-agent). Registered on the Angela agent after
# MCP catalog load so the model still sees the same names.
import net from 'node:net'
import { existsSync } from 'fs'
import { runBrowserAgent } from '../ada-browser.coffee'

callListen = (sockPath, timeout) ->
  new Promise (resolve) ->
    unless existsSync sockPath
      resolve { ok: false, reason: 'unavailable', text: 'listen unavailable (voice socket not up)' }
      return
    acc = ''
    sock = net.connect sockPath, ->
      sock.write JSON.stringify({ cmd: 'listen', timeout: timeout }) + '\n'
    sock.on 'data', (d) ->
      acc += d.toString()
      if acc.includes '\n'
        sock.end()
        try
          resolve JSON.parse acc.split('\n')[0]
        catch e
          resolve { ok: false, reason: 'error', text: e.message }
    sock.on 'error', (e) ->
      resolve { ok: false, reason: 'error', text: e.message }

export registerAdaLocalTools = (agent, { voiceSock } = {}) ->
  return unless agent?.Tool
  agent.Tool 'listen',
    'Listen for Mike\'s next spoken reply. Call after you ask a question or ' +
      'otherwise expect a follow-up. timeout is seconds to wait for him to *start* ' +
      'speaking (default 6); once he is talking, listen continues until 3 seconds of silence. ' +
      'The tool result is a status note only — Mike\'s words arrive as the following user ' +
      'message. Reply to that user message, not to this tool note. ' +
      'Do not call listen if the exchange is complete.'
    { timeout: { type: 'number', description: 'seconds to wait for speech to start (default 6)' } }
    []
    (ctx, args = {}) ->
      sec = Number args.timeout
      sec = 6 unless Number.isFinite(sec) and sec > 0
      result = await callListen voiceSock, sec
      if result.ok and String(result.text or '').trim()
        'Listening done. 1 utterance from Mike follows as the next user message — reply to that.'
      else if result.reason in ['click', 'cancelled', 'replaced']
        'Listening cancelled. No response utterance was heard.'
      else
        'No response utterance was heard.'

  agent.Tool 'control_browser',
    'Delegate a task to a specialized sub-agent that can see and control my ' +
      'web browser: open/navigate/close tabs, read a page, click, fill in ' +
      'forms, scroll, screenshot, wait for content, run JavaScript. Give it ' +
      'one clear task in plain English (e.g. "open chewy.com and tell me my ' +
      'most recent order"); it figures out and performs whatever browser ' +
      'steps are needed and reports back what it found or did.'
    { task: { type: 'string', description: 'the browser task to perform, in plain English' } }
    ['task']
    (ctx, { task } = {}) ->
      await runBrowserAgent task
