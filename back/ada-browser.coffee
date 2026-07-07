# ada-browser — a specialized sub-agent whose only job is controlling the
# Zen browser via mcp-zen's zen_* tools. Invoked by ada-back.coffee as a
# single "control_browser" tool call: Ada hands it one plain-English task,
# waits for its own tool-calling loop to run to completion, and gets back a
# final text response. No output_tool is defined here (see Agent.factory in
# agl-ai) -- the loop just ends on the first plain-text reply, and we read
# that reply via Agent.lastAssistantResponse on the raw result run() returns.
import Agent from 'agl-ai'
import { ensureMcpZen, registerMcpZenTools } from './lib/mcp-zen.coffee'

MODEL = process.env.ADA_MODEL or 'lm-studio:google/gemma-4-e4b'

BROWSER_SYSTEM_PROMPT = '''
  You control a real, already-open web browser through tools: list/open/
  navigate/close tabs, read a page's text or structured elements, click,
  fill in form fields, scroll, take a screenshot, wait for content to
  appear, run JavaScript. You were handed a task by another assistant.
  Use whatever tools and steps are needed to complete it, then reply with
  a short, plain-text summary of what you found or did -- no markdown, no
  further tool calls once you have your answer.
  To click something, prefer zen_click_text with the visible text you want
  (e.g. "click the Bitcoin video", "click Orders") over zen_click. If you do
  use zen_click, its selector must be real CSS that document.querySelector
  accepts -- copy the exact `selector` zen_snapshot gave that element. There
  is no jQuery/Playwright/BeautifulSoup selector engine here, so things like
  :contains(), :has-text(), or :-soup-contains() do not exist and will
  always fail; never invent selector syntax like that.
  '''

# Best-effort warmup at ada-back startup so the first real request doesn't
# pay mcp-zen's startup latency; ensureMcpZen is idempotent and gets called
# again (cheaply, if already up) inside runBrowserAgent regardless.
export initBrowserAgent = ->
  await ensureMcpZen()

export runBrowserAgent = (task) ->
  unless await ensureMcpZen()
    return 'Browser control is not available right now (mcp-zen could not be started).'
  agent = await Agent.factory
    model: MODEL
    parallel_tools: true
    system_prompt: BROWSER_SYSTEM_PROMPT
  registerMcpZenTools agent
  result = await agent.run prompt: task
  Agent.lastAssistantResponse(result) or 'The browser agent finished but did not report a result.'
