#!/usr/bin/env bun
# ada-coach — M6 coach / planner microagent (PLAN2 §2g).
#
# Out-of-band: reads todo next (+ optional tree), decides top-3 priorities,
# strategy, actionable steps, and one "do this now" recommendation, then
# speaks a short upbeat nudge in Ada's voice (unless --quiet / --dry-run).
#
# Usage (from repo or via `ada coach`):
#   bun ada-coach.coffee [--quiet] [--dry-run] [--no-speak] [--list shared] [-n 8]
#
# Run with cwd = back/ (bunfig preloads CoffeeScript) or:
#   bun --preload bun-coffeescript/register ada-coach.coffee

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'
import net from 'node:net'
import yaml from 'js-yaml'
import Agent from 'agl-ai'
import { spawn } from './lib/spawn.coffee'

HERE = dirname fileURLToPath import.meta.url
ADA_ROOT = process.env.ADA_ROOT or join HERE, '..'
CONFIG_PATH = process.env.ADA_CONFIG or join ADA_ROOT, 'config.yaml'
LOGS_DIR = join ADA_ROOT, 'logs'
COACH_OUT = join LOGS_DIR, 'coach-latest.yaml'

loadConfig = ->
  try
    yaml.load(readFileSync CONFIG_PATH, 'utf8') or {}
  catch e
    {}

runCmd = (cmd, args, timeoutMs = 15000) ->
  r = spawn cmd, args
  timer = setTimeout ->
    r.kill? 'SIGKILL'
  , timeoutMs
  try
    await r.promise
  finally
    clearTimeout timer
  {
    ok: r.code is 0
    out: (r.stdout or '').trim()
    err: (r.stderr or '').trim()
    code: r.code
  }

# Presence-voice line protocol (same as ada-back speakOnce).
speakOnce = (sockPath, preset, text, schedule = 'interrupt') ->
  new Promise (resolve, reject) ->
    buf = ''
    settled = false
    done = (fn, arg) ->
      unless settled
        settled = true
        fn arg
    sock = net.connect sockPath, ->
      sock.write "#{preset}\t\t\t#{schedule}\t#{text}\n"
    sock.on 'data', (d) ->
      buf += d.toString()
      if buf.includes '\n'
        sock.end()
        if buf.startsWith 'OK' then done resolve else done reject, new Error(buf.trim())
    sock.on 'error', (e) -> done reject, e
    sock.on 'close', -> done reject, new Error('presence-voice closed early')

SYSTEM = '''
You are Ada's coach microagent — one decision only: what should Mike do next?

Context: Mike is building a hands-free life with Ada. You see his scored open
tasks (todo next) and optional dependency tree. Prefer real progress over
busywork. Be concrete and local (home / personal tasks on this list). Do not
invent tasks that are not on the list. Do not pull employer/work secrets.

Decide:
1) top_three — the three highest-value open items right now (ids + short why)
2) strategy — 2–5 sentence high-level plan across those priorities
3) steps — ordered atomic actions for the lead priority (and others if needed)
4) now_step — exactly one step Mike should do in the next 15–60 minutes
5) speech — what Ada says out loud, unprompted: friendly, upbeat, constructive,
   proactive, ~1–3 short spoken sentences. No markdown. No passphrase jokes.
   Address him as Mike if natural. End with a clear action.

Prefer linear sequencing; call out blockers. If everything scores equally,
pick something finishable soon for momentum.
'''

parseArgs = (argv) ->
  opts =
    quiet: false
    dryRun: false
    speak: true
    list: null
    limit: 8
    tree: true
  i = 0
  while i < argv.length
    a = argv[i]
    switch a
      when '--quiet', '-q' then opts.quiet = true
      when '--dry-run' then opts.dryRun = true; opts.speak = false
      when '--no-speak' then opts.speak = false
      when '--speak' then opts.speak = true
      when '--no-tree' then opts.tree = false
      when '--list', '-l'
        i += 1
        opts.list = argv[i]
      when '-n', '--limit'
        i += 1
        opts.limit = Math.max 3, parseInt(argv[i], 10) or 8
      when '-h', '--help'
        opts.help = true
      else
        if a and not a.startsWith '-'
          opts.list = a
    i += 1
  opts

log = (msg) ->
  console.error "[coach] #{msg}"

# Expand flat tool args into the richer plan shape used for logs / display.
normalizeCoachArgs = (a) ->
  a = a or {}
  top = []
  for i in [1, 2, 3]
    id = String(a["top#{i}_id"] or '').trim()
    title = String(a["top#{i}_title"] or '').trim()
    why = String(a["top#{i}_why"] or '').trim()
    continue unless id or title
    top.push { id, title, why }
  stepsRaw = String(a.steps or '')
  steps = stepsRaw.split(/\n|;|•/).map((s) -> s.replace(/^\s*[-*\d.)]+\s*/, '').trim()).filter (s) -> s.length
  {
    top_three: top
    strategy: String(a.strategy or '').trim()
    steps: steps
    now_step: String(a.now_step or '').trim()
    speech: String(a.speech or '').trim()
    task_ids: (t.id for t in top when t.id)
  }

main = ->
  opts = parseArgs process.argv.slice 2
  if opts.help
    console.log '''
      ada coach — proactive task coach (M6)

      usage:
        ada coach [--quiet] [--dry-run] [--no-speak] [--list shared] [-n 8]

      Reads todo next (+ tree), runs a microagent, prints JSON, optionally
      speaks a short Ada nudge via presence-voice.
      '''
    process.exit 0

  config = loadConfig()
  model = process.env.ADA_MODEL or config.model or ''

  voice = process.env.ADA_VOICE or config.voice or 'nova'
  presenceSock = process.env.ADA_PRESENCE_SOCK or '/tmp/presence-voice.sock'
  list = opts.list or config.task_lists?.shared or 'shared'
  # todo CLI: -l is list label for some commands; next uses env TODO_SHARED
  if typeof list is 'string' and list.includes '/'
    process.env.TODO_SHARED = list
    listLabel = null
  else
    listLabel = list

  # Gather deterministic inputs
  nextArgs = ['next', '-n', String(opts.limit)]
  if listLabel then nextArgs.push '-l', listLabel
  nextRes = await runCmd 'todo', nextArgs
  unless nextRes.ok
    log "todo next failed (#{nextRes.code}): #{nextRes.err or nextRes.out}"
  nextText = nextRes.out or nextRes.err or '(no tasks)'

  treeText = ''
  if opts.tree
    treeArgs = ['tree']
    if listLabel then treeArgs.push '-l', listLabel
    treeRes = await runCmd 'todo', treeArgs
    treeText = treeRes.out or ''
    if treeText.length > 6000
      treeText = treeText.slice(0, 6000) + '\n…(truncated)'

  log "list=#{listLabel or process.env.TODO_SHARED} model=#{model}"
  log "todo next:\n#{nextText.split('\n').slice(0, 12).join('\n')}"

  if opts.dryRun and process.env.ADA_COACH_SKIP_LLM is '1'
    # Deterministic smoke without LLM
    result =
      top_three: [{ id: 'dry', title: 'dry-run', why: 'skip llm' }]
      strategy: 'dry-run'
      steps: ['dry-run']
      now_step: 'dry-run step'
      speech: 'Dry run only. No spoken coach.'
      task_ids: []
    console.log JSON.stringify result, null, 2
    process.exit 0

  # Flat string fields: Gemma is unreliable with nested array/object tool schemas
  # (empty tool_calls + infinite nudge). Keep the one-decision microagent shape.
  decision = null
  # Do not set max_tokens: Gemma often spends the whole budget on
  # reasoning_content, hits finish_reason=length with empty tool_calls, and
  # then agl's coach_plan nudge loop never completes.
  agent = await Agent.factory
    model: model
    reasoning_effort: 'xhigh'
    tool_choice: 'required'
    system_prompt: SYSTEM
    output_tool:
      name: 'coach_plan'
      description: 'One coaching decision: priorities, strategy, and what Mike should do now.'
      parameters:
        top1_id: { type: 'string', description: 'Id of #1 priority task from the list' }
        top1_title: { type: 'string', description: 'Title of #1 priority' }
        top1_why: { type: 'string', description: 'Why this is #1 right now' }
        top2_id: { type: 'string', description: 'Id of #2 priority (or empty)' }
        top2_title: { type: 'string', description: 'Title of #2' }
        top2_why: { type: 'string', description: 'Why #2' }
        top3_id: { type: 'string', description: 'Id of #3 priority (or empty)' }
        top3_title: { type: 'string', description: 'Title of #3' }
        top3_why: { type: 'string', description: 'Why #3' }
        strategy:
          type: 'string'
          description: 'High-level overall strategy across the top priorities (2–5 sentences)'
        steps:
          type: 'string'
          description: 'Ordered atomic steps for the lead work, newline- or semicolon-separated'
        now_step:
          type: 'string'
          description: 'Single concrete action for Mike in the next 15–60 minutes'
        speech:
          type: 'string'
          description: '1–3 short spoken sentences for Ada to say unprompted (no markdown)'
      required: ['top1_id', 'top1_title', 'top1_why', 'strategy', 'steps', 'now_step', 'speech']
      fn: (ctx, args) ->
        decision = normalizeCoachArgs args
        decision

  prompt = """
    <todo-next>
    #{nextText}
    </todo-next>
    <todo-tree>
    #{treeText or '(not requested)'}
    </todo-tree>
    Produce coach_plan for Mike right now.
    """

  # Hard timeout so a stuck model cannot hang the subcommand forever
  timeoutMs = Number(process.env.ADA_COACH_TIMEOUT_MS or config.planner?.timeout_ms or 90000)
  timedOut = false
  runP = agent.run(prompt: prompt).catch (e) ->
    if timedOut then null else Promise.reject e
  timer = setTimeout ->
    timedOut = true
    try
      agent.abort? 'coach timeout'
    catch e then null
  , timeoutMs

  try
    await runP
  catch e
    unless timedOut
      log "microagent failed: #{e.message}"
      console.error e
      process.exit 1
  finally
    clearTimeout timer

  if timedOut and not decision
    console.error 'error: coach microagent timed out'
    process.exit 1

  decision or= agent.last_output or {}
  speech = String(decision.speech or '').replace(/[\t\n]+/g, ' ').trim()
  unless speech
    speech = "Mike, let's keep momentum: #{decision.now_step or 'pick one small task from your list and start it'}."

  # Persist for debugging / future diary
  try
    mkdirSync LOGS_DIR, recursive: true
    writeFileSync COACH_OUT, yaml.dump({
      ts: new Date().toISOString()
      list: listLabel or process.env.TODO_SHARED
      decision
      speech
    }, { lineWidth: 100, noRefs: true }), 'utf8'
    log "wrote #{COACH_OUT}"
  catch e
    log "could not write coach log: #{e.message}"

  # Human-readable stdout (and JSON if QUIET machine mode)
  if opts.quiet
    console.log JSON.stringify { decision, speech }
  else
    console.log ''
    console.log '=== Ada coach ==='
    console.log "Now: #{decision.now_step or speech}"
    if decision.top_three?.length
      console.log 'Top 3:'
      for t, i in decision.top_three
        console.log "  #{i + 1}. [#{t.id or '?'}] #{t.title or ''} — #{t.why or ''}"
    if decision.strategy
      console.log "Strategy: #{decision.strategy}"
    if decision.steps?.length
      console.log 'Steps:'
      for s in decision.steps
        console.log "  - #{s}"
    console.log "Speech: #{speech}"
    console.log ''

  if opts.speak and speech
    unless existsSync presenceSock.replace(/^unix:\/\//, '')
      # sock path is bare path
      null
    try
      log "speaking (#{voice}): #{speech.slice 0, 80}…"
      await speakOnce presenceSock, voice, speech, 'interrupt'
      log 'spoke ok'
    catch e
      log "speak failed: #{e.message} (is presence-voice up?)"
      # Non-fatal: plan still printed
      process.exitCode = 0

  process.exit 0

main().catch (e) ->
  console.error e
  process.exit 1
