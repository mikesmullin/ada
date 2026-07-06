#!/usr/bin/env bun
# ada-back — the persistent conversation loop (docs/PLAN.md §6).
#
# Pipeline: perception-voice `subscribe words` (partials + utterances)
#   → activation gate (PTT overlap / wake word / conversation window)
#   → agl agent turn (lm-studio, token streaming)
#   → sentence splitter → presence-voice speak, sentence by sentence
#   → state events to the avatar at every transition.
#
# The back is the unix-socket *server* for the avatar (JSON lines,
# docs/PROTOCOL.md §4) and a *client* of both voice services.
#
# Run with `bun ada-back.coffee` from this directory — bunfig.toml preloads
# bun-coffeescript/register so Bun executes .coffee natively.

import Agent from 'agl-ai'
import yaml from 'js-yaml'
import net from 'node:net'
import { existsSync, readFileSync, readdirSync, unlinkSync, writeFileSync } from 'fs'
import { spawn } from './lib/spawn.coffee'
import { clamp, forceInt, forceRx } from './lib/validate.coffee'

# ---------------------------------------------------------------------------
# Single-instance lock: a second back would steal the avatar socket and
# double-run every turn. Pidfile + liveness check (no flock in JS): a
# stale file from a crash is detected via kill(pid, 0) and taken over.

LOCK_PATH = new URL('../.back.lock', import.meta.url).pathname

acquireInstanceLock = ->
  try
    pid = Number readFileSync(LOCK_PATH, 'utf8').trim()
    if pid and pid isnt process.pid
      try
        process.kill pid, 0 # throws if not running
        console.error "error: another ada-back is already running (pid #{pid}, lock: #{LOCK_PATH})"
        console.error '       stop it first: systemctl --user stop ada-back'
        process.exit 1
      catch e then null # stale lock from a dead process — take over
  catch e then null # no lock file
  writeFileSync LOCK_PATH, "#{process.pid}\n"

releaseInstanceLock = ->
  try
    unlinkSync LOCK_PATH if Number(readFileSync(LOCK_PATH, 'utf8').trim()) is process.pid
  catch e then null # already gone

CFG =
  backSock: process.env.ADA_BACK_SOCK or
    "#{process.env.XDG_RUNTIME_DIR or '/tmp'}/ada-back.sock"
  perceptionSock: process.env.ADA_PERCEPTION_SOCK or
    '/workspace/perception-voice/perception.sock'
  presenceSock: process.env.ADA_PRESENCE_SOCK or '/tmp/presence-voice.sock'
  voice: process.env.ADA_VOICE or 'ada'
  model: process.env.ADA_MODEL or 'lm-studio:google/gemma-4-e4b'
  wake: new RegExp(process.env.ADA_WAKE or '\\bada\\b', 'i')
  convWindowMs: Number(process.env.ADA_CONV_WINDOW_MS or 8000)
  activityDir: process.env.ADA_ACTIVITY_DIR or '/workspace/mari/activity'
  sfxDir: new URL('../sfx/', import.meta.url).pathname
  historyMax: 24

log = (a...) -> console.log "[#{new Date().toISOString().slice 11, 23}]", a...

# ---------------------------------------------------------------------------
# State machine + avatar socket server (JSON lines)

state = { listening: false, active: false, thinking: false, speaking: false }
avatars = new Set()

broadcast = (obj) ->
  line = JSON.stringify(obj) + '\n'
  for s from avatars
    try s.write line
    catch e then null # dropped on close

setState = (patch) ->
  changed = false
  for k in Object.keys patch
    if state[k] isnt patch[k]
      state[k] = patch[k]
      changed = true
  broadcast { ev: 'state', state... } if changed

startAvatarServer = ->
  unlinkSync CFG.backSock if existsSync CFG.backSock
  server = net.createServer (sock) ->
    avatars.add sock
    sock.write JSON.stringify({ ev: 'state', state... }) + '\n'
    log 'avatar connected'
    acc = ''
    sock.on 'data', (buf) ->
      acc += buf.toString()
      while (idx = acc.indexOf '\n') >= 0
        line = acc.slice(0, idx).trim()
        acc = acc.slice idx + 1
        continue unless line
        try onAvatarEvent JSON.parse(line)
        catch e then log 'bad avatar line:', line
    sock.on 'close', ->
      avatars.delete sock
      log 'avatar disconnected'
    sock.on 'error', -> avatars.delete sock
  server.listen CFG.backSock
  log "avatar server listening on unix://#{CFG.backSock}"

# ---------------------------------------------------------------------------
# PTT + activation gate

pttDown = false
pttIntervals = [] # {down, up} unix seconds, recent only
convWindowUntil = 0

onAvatarEvent = (ev) ->
  switch ev.ev
    when 'ptt'
      now = Date.now() / 1000
      if ev.down and not pttDown
        pttDown = true
        pttIntervals.push { down: now, up: null }
        sfx 'squelch-on'
        setState active: true
      else if not ev.down and pttDown
        pttDown = false
        pttIntervals.at(-1).up = now
        pttIntervals.shift() while pttIntervals.length > 8
        sfx 'click-off'
        maybeIdle()
    when 'click'
      cancelAll 'click'
    when 'quit'
      log 'avatar quit'

# An utterance passes if PTT overlapped its time window, it names Ada, or
# it falls inside the post-exchange conversation window (plan §6.2).
activationGate = (utt) ->
  SLOP = 0.3 # seconds — VAD tails and clock slop
  return 'ptt' if pttDown
  if utt.t_start and utt.t_end
    for iv in pttIntervals
      up = iv.up ? Date.now() / 1000
      return 'ptt' if iv.down <= utt.t_end + SLOP and up >= utt.t_start - SLOP
  return 'wake' if CFG.wake.test utt.text
  return 'window' if Date.now() < convWindowUntil
  null

maybeIdle = ->
  if not currentTurn and not pttDown and Date.now() >= convWindowUntil
    setState active: false

# ---------------------------------------------------------------------------
# sfx feedback (borrowed from /workspace/whisper's proven set)

sfx = (name) ->
  path = "#{CFG.sfxDir}#{name}.wav"
  spawn 'paplay', [path] if existsSync path # fire and forget

# ---------------------------------------------------------------------------
# presence-voice speaker: one in-flight request at a time serializes our
# sentence queue; the daemon's FIFO speech channel makes them gapless.

class Speaker
  constructor: ->
    @queue = []
    @pumping = false

  # schedule: 'enqueue' (default — sentences of one reply queue gapless on
  # the daemon's FIFO speech channel) or 'interrupt' (silence anything
  # already playing first — a new turn's opening sentence).
  enqueue: (text, turn, schedule = 'enqueue') ->
    clean = text.replace(/[\t\n]+/g, ' ').trim()
    return unless clean
    @queue.push { text: clean, turn, schedule }
    @pump()

  clear: -> @queue.length = 0

  pump: ->
    return if @pumping
    @pumping = true
    try
      while @queue.length
        { text, turn, schedule } = @queue.shift()
        continue if turn?.cancelled
        setState speaking: true
        t0 = performance.now()
        try
          await speakOnce CFG.voice, text, schedule
          turn.lat.lastAudioDone = performance.now() if turn?.lat
          log "spoke [#{schedule}] (#{Math.round performance.now() - t0}ms): #{text}"
        catch e
          log "speak failed: #{e.message} — \"#{text}\""
    finally
      @pumping = false
      setState speaking: false
      unless currentTurn
        convWindowUntil = Date.now() + CFG.convWindowMs
        setTimeout maybeIdle, CFG.convWindowMs + 50

speakOnce = (preset, text, schedule = 'enqueue') ->
  new Promise (resolve, reject) ->
    buf = ''
    settled = false
    done = (fn, arg) ->
      unless settled
        settled = true
        fn arg
    sock = net.connect CFG.presenceSock, ->
      # presence-voice line protocol:
      # preset \t speaker \t effects \t schedule \t text
      # (empty speaker/effects = daemon defaults; schedule is required)
      sock.write "#{preset}\t\t\t#{schedule}\t#{text}\n"
    sock.on 'data', (d) ->
      buf += d.toString()
      if buf.includes '\n'
        sock.end()
        if buf.startsWith 'OK' then done resolve else done reject, new Error(buf.trim())
    sock.on 'error', (e) -> done reject, e
    sock.on 'close', -> done reject, new Error('presence-voice closed early')

# The daemon's stop primitive: interrupt with empty text silences any
# playing/queued speech without saying anything.
stopSpeech = ->
  speakOnce(CFG.voice, '', 'interrupt').catch (e) -> log "stop failed: #{e.message}"

speaker = new Speaker()

# ---------------------------------------------------------------------------
# Sentence splitter over the token stream: speak each sentence the moment
# it completes instead of waiting for the full reply (plan §6.4).

class SentenceSplitter
  constructor: (@onSentence) ->
    @acc = ''

  push: (delta) ->
    @acc += delta
    while (m = @acc.match /^(.*?[.!?])(?:\s+|$)(?=\S|$)/s) and /\S{2,}/.test m[1]
      sentence = m[1].trim()
      @acc = @acc.slice m[0].length
      @onSentence sentence if sentence
      break unless @acc

  flush: ->
    rest = @acc.trim()
    @acc = ''
    @onSentence rest if rest

# ---------------------------------------------------------------------------
# Tools

# mari activity configs: aliased app launches + named commands (plan §9.2)
loadActivities = ->
  apps = {}     # app name -> full shell line
  commands = {} # "activity.key" -> shell line
  return { apps, commands } unless existsSync CFG.activityDir
  for f in readdirSync CFG.activityDir
    continue unless f.endsWith('.yml') or f.endsWith('.yaml')
    try
      doc = yaml.load readFileSync("#{CFG.activityDir}/#{f}", 'utf8')
    catch e then continue
    continue unless doc?.name
    if doc.shell_aliases
      for target in Object.values doc.shell_aliases
        apps[target] = if doc.shell_prefix then "#{doc.shell_prefix} #{target}" else target
    if doc.commands
      for own key, val of doc.commands
        shell = if typeof val is 'string' then val else val?.shell
        commands["#{doc.name}.#{key}"] = shell if typeof shell is 'string'
  { apps, commands }

activities = loadActivities()
log "activities: #{Object.keys(activities.apps).length} apps, #{Object.keys(activities.commands).length} commands"

# Run a tool command without ever throwing: a missing binary or non-zero
# exit becomes a failure *string* the LLM can relay ("the desk lamp
# didn't respond") instead of an exception that aborts the whole turn as
# "Sorry, something went wrong".
runCmd = (cmd, args) ->
  try
    child = spawn cmd, args.map(String)
    await child.promise
    { ok: child.code is 0, out: (child.stdout + child.stderr).trim().slice(0, 200) }
  catch e
    { ok: false, out: "#{cmd}: #{e.message}" }

# Launcher-style commands may run long (apps, sessions): report started
# rather than hanging the turn.
shellTool = (shellLine, timeoutMs = 10000) ->
  try
    child = spawn 'bash', ['-c', shellLine]
    timeout = new Promise (r) -> setTimeout (-> r 'TIMEOUT'), timeoutMs
    result = await Promise.race [child.promise, timeout]
    return "started (still running): #{shellLine}" if result is 'TIMEOUT'
    if child.code is 0
      "ok: #{shellLine}#{if child.stdout then " — #{child.stdout.trim().slice 0, 200}" else ''}"
    else
      "failed (exit #{child.code}): #{shellLine} — #{(child.stderr or child.stdout).trim().slice 0, 200}"
  catch e
    "failed: #{shellLine} — #{e.message}"

registerTools = (agent) ->
  # -- home lights, ported from agl home.mjs --------------------------------
  agent.Tool 'desk_light',
    'control power and/or light color emitted by my govee RGB LED desk lamp. ' +
    'If the request names or implies a color (e.g. "turn it blue"), you MUST provide r, g, and b together. ' +
    'Only provide power when the request is purely about turning the lamp on/off, with no color mentioned.',
    power: { type: 'boolean', description: 'turn the lamp on or off. omit unless the request is only about power.' }
    r: { type: 'integer', description: 'red 0-255, required together with g and b when a color is requested.' }
    g: { type: 'integer', description: 'green 0-255, required together with r and b when a color is requested.' }
    b: { type: 'integer', description: 'blue 0-255, required together with r and g when a color is requested.' }
    brightness: { type: 'integer', description: 'range 0-35; perceived brightness is non-linear, finer at low values.' }
  , [], (ctx, { power, r, g, b, brightness }) ->
    result = ''
    if typeof power is 'boolean'
      res = await runCmd 'govee', [if power then 'on' else 'off']
      result += if res.ok then "lamp power is now #{if power then 'on' else 'off'}. " \
                else "failed to set lamp power (#{res.out}). "
    if r isnt undefined or g isnt undefined or b isnt undefined
      r = clamp forceInt(r, 0), 0, 255
      g = clamp forceInt(g, 0), 0, 255
      b = clamp forceInt(b, 0), 0, 255
      res = await runCmd 'govee', ['rgb', r, g, b]
      result += if res.ok then "lamp color is now rgb(#{r},#{g},#{b}). " \
                else "failed to set lamp color (#{res.out}). "
    if brightness
      brightness = clamp forceInt(brightness, 0), 0, 35
      res = await runCmd 'govee', ['brightness', brightness]
      result += if res.ok then "lamp brightness=#{brightness}." \
                else "failed to set lamp brightness (#{res.out})."
    result or 'no lamp action requested.'

  agent.Tool 'pc_light_color',
    'control light color emitted by my desktop PC tower chassis LED strip',
    color: { type: 'string', description: 'hex format, e.g. FF0000' }
    brightness: { type: 'integer', description: 'range 0-50. default 50' }
  , ['color'], (ctx, { color, brightness = 50 }) ->
    color = forceRx /^[0-9A-Fa-f]{6}$/, color, '000000'
    brightness = clamp forceInt(brightness, 0), 0, 50
    res = await runCmd 'openrgb', ['-d', '0', '--mode', 'static', '--color', color, '--brightness', brightness]
    if res.ok
      "PC light is now color=#{color} brightness=#{brightness}."
    else
      "failed to set PC light color (#{res.out})."

  agent.Tool 'current_time',
    'get the current local date, time, and timezone', {}, [], ->
      now = new Date()
      tz = Intl.DateTimeFormat().resolvedOptions().timeZone
      local = now.toLocaleString 'en-US',
        weekday: 'long', year: 'numeric', month: 'long', day: 'numeric'
        hour: 'numeric', minute: '2-digit', second: '2-digit', timeZoneName: 'short'
      "#{local} (timezone #{tz}; ISO #{now.toISOString()})"

  # -- app launching ---------------------------------------------------------
  # Open-ended but shell-safe (mari's `!` SHELL-mode semantics): the app
  # name must be one bare token — no spaces, slashes, or shell metachars —
  # passed as a single argv to ~/launch.sh, which nohup-execs it as a
  # program name. Nothing to inject into and no arguments possible, so the
  # worst case is launching some argument-less program by name.
  appNames = Object.keys activities.apps
  agent.Tool 'run_application',
    'launch a desktop application by its program name (as found on PATH), ' +
    'e.g. audacity, discord, zen-browser. Use the plain lowercase binary ' +
    'name, a single word.' +
    (if appNames.length then " Known favorites: #{appNames.join ', '}." else ''),
    app: { type: 'string', description: 'program name: one word, lowercase, no spaces or paths' }
  , ['app'], (ctx, { app }) ->
    name = String(app ? '').trim()
    unless /^[A-Za-z0-9._+-]{1,64}$/.test name
      return "refused: \"#{name}\" is not a plain program name (one word, no spaces or paths)"
    res = await runCmd "#{process.env.HOME}/launch.sh", [name]
    if res.ok then "launched #{name}." else "failed to launch #{name} (#{res.out})"

  cmdIds = Object.keys activities.commands
  if cmdIds.length
    listing = cmdIds.map((id) -> "#{id}: #{activities.commands[id]}").join '\n'
    agent.Tool 'run_activity_command',
      'run one of my predefined activity commands (home automation, work laptop, sessions). ' +
      "Available commands (id: shell):\n#{listing}",
      id: { type: 'string', enum: cmdIds, description: 'the command id to run' }
    , ['id'], (ctx, { id }) ->
      line = activities.commands[id]
      return "unknown command: #{id}" unless line
      shellTool line

# ---------------------------------------------------------------------------
# Turn engine

# SOUL.md: standing knowledge (who Mike is, preferences, facts) appended
# to the system prompt at startup — edit the file, restart the back.
SOUL_PATH = process.env.ADA_SOUL or new URL('../SOUL.md', import.meta.url).pathname

loadSoul = ->
  try
    soul = readFileSync(SOUL_PATH, 'utf8').trim()
    log "soul loaded: #{SOUL_PATH} (#{soul.length} chars)"
    "\n\nStanding knowledge (from your SOUL.md — treat as true and current):\n#{soul}"
  catch e
    log "no soul file at #{SOUL_PATH}"
    ''

BASE_PROMPT = '''
  You are Ada, a spoken-voice desktop assistant. Your replies are read
  aloud by a text-to-speech engine, so: be conversational and concise
  (usually one or two short sentences), never use markdown, bullet
  points, emoji, or headings, and spell things the way they should be
  spoken. You hear the user through an always-on microphone; transcripts
  may contain small transcription errors — infer the intent.
  You can control the home with tools. There are two independently
  controllable lights: the desk lamp (desk_light) and the PC tower LED
  strip (pc_light_color). When the user says "lights" (plural) or does
  not name a specific light, apply the request to BOTH lights. Call each
  necessary tool at most once. You can also launch desktop apps by their
  program name (run_application, e.g. audacity, discord) and run
  predefined activity commands (run_activity_command).
  If the user is just talking, just talk back — do not use tools.
  '''

SYSTEM_PROMPT = BASE_PROMPT + loadSoul()

history = []
currentTurn = null
turnCounter = 0

renderPrompt = (text) ->
  recent = history.slice -CFG.historyMax
  ctx = recent.map((h) -> "#{h.who}: #{h.text}").join '\n'
  (if ctx then "(recent conversation for context:\n#{ctx})\n\n" else '') + text

runTurn = (utt, gate) ->
  # barge-in: a new passing utterance cancels whatever is pending/speaking —
  # clear our queue AND silence the daemon immediately (don't wait for the
  # reply's first sentence to interrupt)
  if currentTurn
    currentTurn.cancelled = true
    stopSpeech()
  speaker.clear()

  turn =
    id: ++turnCounter
    cancelled: false
    reply: ''
    lat:
      eou: if utt.t_end then utt.t_end * 1000 else null # unix ms, perception clock
      utteranceArrived: Date.now()
      start: performance.now()
      firstToken: null
      firstSentence: null
      lastAudioDone: null
  currentTurn = turn

  sfx 'activate' unless gate is 'ptt'
  setState active: true, thinking: true
  log "turn #{turn.id} [#{gate}]: #{utt.text}"

  splitter = new SentenceSplitter (sentence) ->
    return if turn.cancelled
    # opening sentence interrupts (kills any stale speech a cancelled turn
    # managed to get in flight); the rest of the reply enqueues gapless
    first = turn.lat.firstSentence is null
    turn.lat.firstSentence = performance.now() if first
    speaker.enqueue sentence, turn, (if first then 'interrupt' else 'enqueue')

  try
    # fresh agent per turn so a cancelled turn's late tokens stream into its
    # own dead splitter, never the new turn's
    agent = await Agent.factory
      model: CFG.model
      parallel_tools: true
      stream: true
      system_prompt: SYSTEM_PROMPT
      on_delta: (d) ->
        return if turn.cancelled
        turn.lat.firstToken = performance.now() if turn.lat.firstToken is null
        turn.reply += d
        splitter.push d
    registerTools agent
    await agent.run prompt: renderPrompt(utt.text)
  catch e
    log "turn #{turn.id} error: #{e.message}"
    speaker.enqueue 'Sorry, something went wrong.', turn unless turn.cancelled
  splitter.flush()

  unless turn.cancelled
    history.push { who: 'user', text: utt.text }
    history.push { who: 'ada', text: turn.reply.trim() } if turn.reply.trim()
    history.shift() while history.length > CFG.historyMax * 2

  if currentTurn is turn
    currentTurn = null
    setState thinking: false
    convWindowUntil = Date.now() + CFG.convWindowMs
    setTimeout maybeIdle, CFG.convWindowMs + 50

  # latency report (plan §7)
  l = turn.lat
  ms = (v) -> if v is null then ' n/a' else "#{Math.round v - l.start}ms"
  eouToArrive = if l.eou then "#{Math.round l.utteranceArrived - l.eou}ms" else 'n/a'
  log "turn #{turn.id} latency: eou→utterance=#{eouToArrive} " +
    "utterance→first_token=#{ms l.firstToken} first_sentence=#{ms l.firstSentence} " +
    "speech_done=#{ms l.lastAudioDone}#{if turn.cancelled then ' (cancelled)' else ''}"

cancelAll = (reason) ->
  if currentTurn
    log "cancel (#{reason}): turn #{currentTurn.id}"
    currentTurn.cancelled = true
    currentTurn = null
  speaker.clear()
  stopSpeech() # silence anything already playing, whisper-style cancel
  sfx 'click-off'
  convWindowUntil = 0
  setState thinking: false, active: pttDown

# ---------------------------------------------------------------------------
# perception-voice words stream (framed JSON: 4-byte BE length + payload)

frameJson = (obj) ->
  payload = Buffer.from JSON.stringify(obj), 'utf8'
  header = Buffer.alloc 4
  header.writeUInt32BE payload.length
  Buffer.concat [header, payload]

onWordsEvent = (msg) ->
  if msg.ev is 'partial'
    # pre-activation feedback: light the orb up as soon as the wake word (or
    # a held PTT) is heard, before the utterance even finalizes
    if not state.active and (pttDown or CFG.wake.test(msg.text or ''))
      setState active: true
    return
  if msg.ev is 'utterance'
    gate = activationGate msg
    unless gate
      log "(unaddressed) #{msg.text}"
      maybeIdle()
      return
    runTurn msg, gate # async; not awaited — barge-in handles overlap

connectWords = (isRetry = false) ->
  acc = Buffer.alloc 0
  subscribed = false
  sock = net.connect CFG.perceptionSock, ->
    sock.write frameJson(command: 'subscribe', channel: 'words')
  sock.on 'data', (d) ->
    acc = Buffer.concat [acc, d]
    while acc.length >= 4
      len = acc.readUInt32BE 0
      break if acc.length < 4 + len
      payload = acc.subarray 4, 4 + len
      acc = acc.subarray 4 + len
      try
        msg = JSON.parse payload.toString('utf8')
      catch e then continue
      if not subscribed
        if msg.status is 'ok'
          subscribed = true
          setState listening: true
          log 'subscribed to perception-voice words stream'
        else
          log "words subscribe rejected: #{JSON.stringify msg}"
          sock.end()
      else
        onWordsEvent msg
  sock.on 'error', (e) ->
    if not isRetry and not subscribed
      console.error "error: perception-voice is not reachable (unix://#{CFG.perceptionSock})"
      console.error '       start it: systemctl --user start perception-voice'
      process.exit 1
  sock.on 'close', ->
    setState listening: false
    log 'words stream lost; reconnecting…'
    setTimeout (-> connectWords true), 1000

# ---------------------------------------------------------------------------
# startup

main = ->
  acquireInstanceLock()
  Agent.default.concurrency = 4 # let a barge-in turn start while a cancelled one drains

  # fail fast if presence-voice isn't up (plan §9.3); systemd retries us.
  # Connect-only probe: the daemon closes wordlessly on bad requests, so
  # reachability (connect succeeds) is the only safe health signal.
  try
    await new Promise (resolve, reject) ->
      sock = net.connect CFG.presenceSock, ->
        sock.end()
        resolve()
      sock.on 'error', reject
  catch e
    console.error "error: presence-voice daemon is not reachable (unix://#{CFG.presenceSock})"
    console.error '       start it: systemctl --user start voice'
    process.exit 1

  startAvatarServer()
  connectWords()
  log "ada-back ready (voice=#{CFG.voice} model=#{CFG.model} wake=#{CFG.wake})"

  # ADA_SELFTEST="<text>": run one synthetic utterance through the full
  # turn pipeline (gate → agent → splitter → speaker → latency report)
  # as if perception-voice had just finalized it. Dev tool; no mic needed.
  if process.env.ADA_SELFTEST
    now = Date.now() / 1000
    setTimeout ->
      onWordsEvent
        ev: 'utterance'
        ts: now
        text: process.env.ADA_SELFTEST
        t_start: now - 2
        t_end: now
    , 1500

['SIGINT', 'SIGTERM'].forEach (sig) ->
  process.on sig, ->
    try
      unlinkSync CFG.backSock if existsSync CFG.backSock
    catch e then null
    releaseInstanceLock()
    process.exit 0
process.on 'exit', releaseInstanceLock

await main()
