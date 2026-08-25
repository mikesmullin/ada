#!/usr/bin/env bun
# ada-back — the persistent conversation loop (docs/PLAN.md §6).
#
# Pipeline: perception-voice `subscribe words` (partials + utterances)
#   → activation gate (PTT overlap / wake word) or listen-tool waiter
#   → Angela session.run (agl retain_history + jsonl)
#   → sentence splitter → presence-voice speak, sentence by sentence
#   → state events to the avatar at every transition.
#
# The back is the unix-socket *server* for the avatar (JSON lines,
# docs/PROTOCOL.md §4) and a *client* of both voice services.
#
# Run with `bun ada-back.coffee` from this directory — bunfig.toml preloads
# bun-coffeescript/register so Bun executes .coffee natively.

import Agent from 'agl-ai'
import { Angela } from 'angela'
import yaml from 'js-yaml'
import net from 'node:net'
import { dirname, join } from 'node:path'
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'fs'
import { spawn } from './lib/spawn.coffee'
import { initBrowserAgent } from './ada-browser.coffee'
import { ensureBrainMcp, resolveAdaBrain } from './lib/mcp-brain.coffee'
import { ensureTodoMcp } from './lib/mcp-todo.coffee'
import {
  joinToolWave, registerToolWaveGate, runTomInWave
  feedUtterance as tomFeedUtterance, isWaiting as tomIsWaiting
  denyAllPending as tomDenyAllPending
} from './lib/tom.coffee'
import {
  startProgress, stopProgress, isWaiting as progressIsWaiting
  feedUtterance as progressFeedUtterance, isLongTool
} from './lib/progress.coffee'
import { announceTool } from './lib/tool-announce.coffee'
import {
  connectLevels, createListenSession, createTranscriptBuf
  feedPartial, feedUtterance as gatherFeedUtterance, snapshotText
} from './lib/listen.coffee'
import { compactContextWindow } from './lib/compact.coffee'

# UX wrap only (announce caption + long-tool progress). Allowlist + Tom live
# in Angela PolicyEngine (onApproval).
wrapToolsForUx = (agent) ->
  for name in Object.keys agent.tools
    do (name) ->
      fn = agent.tools[name]
      wrapped = (ctx, args) ->
        argPreview = try JSON.stringify(args ? {}).slice(0, 240) catch e then String(args)
        log "tool → #{name} #{argPreview}"
        try
          # listen arms immediately — announce would delay the waiter (~2s)
          # and drop speech as (unaddressed). Caption is `(listening)`.
          unless name is 'listen'
            try
              line = await announceTool
                toolName: name
                args: args
                model: CFG.model
                log: log
              speaker.caption line if line
            catch e
              log "announce error: #{e.message}"

          # Long tools: progress ticks + cancel phrase (PLAN2 M5).
          useProgress = isLongTool name, CFG.progressTools
          progress = null
          if useProgress
            progress = startProgress
              toolName: name
              args: args
              intervalMs: CFG.progressIntervalMs
              cancelPrefix: CFG.progressCancelPrefix
              speakOnce: speakOnce
              broadcast: broadcast
              voice: CFG.voice
              log: log
            if ctx?
              ctx.__progressSetKill = progress.setKill

          try
            if useProgress
              toolP = Promise.resolve().then(-> fn ctx, args)
                .then (r) -> { kind: 'done', r }
                .catch (e) -> { kind: 'error', e }
              result = await Promise.race [
                toolP
                progress.cancelPromise.then (c) -> { kind: 'cancel', c }
              ]
              if result.kind is 'cancel'
                toolP.catch -> null
                out = "error: user aborted tool #{name}. " +
                  "The operation was cancelled mid-flight and did not complete successfully. " +
                  "Do not invent partial success; tell Mike it was cancelled."
                log "tool ← #{name} #{out}"
                return out
              if result.kind is 'error'
                throw result.e
              out = result.r
            else
              out = await fn ctx, args
            preview = String(out ? '').replace(/\s+/g, ' ').slice(0, 240)
            log "tool ← #{name} #{preview}"
            out
          catch e
            log "tool ✗ #{name} #{e.message}"
            throw e
          finally
            progress?.stop()
      wrapped._name = fn._name
      wrapped._description = fn._description
      wrapped._properties = fn._properties
      wrapped._required = fn._required
      agent.tools[name] = wrapped

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

# ---------------------------------------------------------------------------
# config.yaml: user-tunable settings (voice preset, ...) that are nicer to
# hand-edit than an env var. Env vars still win when set, for quick one-off
# overrides without touching the file.
CONFIG_PATH = process.env.ADA_CONFIG or new URL('../config.yaml', import.meta.url).pathname

loadConfig = ->
  try
    yaml.load readFileSync(CONFIG_PATH, 'utf8')
  catch e
    console.log "no config.yaml at #{CONFIG_PATH} (#{e.message}) — using defaults"
    {}

config = loadConfig() or {}

ADA_ROOT = new URL('..', import.meta.url).pathname.replace(/\/$/, '')

# Prefer the `ada` alias from `brain use` so Ada's MCP instance hits her db
# even if some other brain is selected in an interactive shell.
ADA_BRAIN = resolveAdaBrain
  cwd: process.env.ADA_BRAIN_CWD or ADA_ROOT
  root: process.env.ADA_BRAIN or process.env.BRAIN_ROOT or
    config.brain_path or "#{ADA_ROOT}/db"

CFG =
  backSock: process.env.ADA_BACK_SOCK or
    "#{process.env.XDG_RUNTIME_DIR or '/tmp'}/ada-back.sock"
  perceptionSock: process.env.ADA_PERCEPTION_SOCK or
    '/workspace/perception-voice/perception.sock'
  presenceSock: process.env.ADA_PRESENCE_SOCK or '/tmp/presence-voice.sock'
  voice: process.env.ADA_VOICE or config.voice or 'ada'
  model: process.env.ADA_MODEL or process.env.FAV_LOCAL_LLM
  wake: new RegExp(process.env.ADA_WAKE or '\\bada\\b', 'i')
  activityDir: process.env.ADA_ACTIVITY_DIR or '/workspace/mari/activity'
  sfxDir: new URL('../sfx/', import.meta.url).pathname
  voiceSock: process.env.ADA_VOICE_SOCK or
    "#{process.env.XDG_RUNTIME_DIR or '/tmp'}/ada-voice.sock"
  sessionFile: process.env.ADA_SESSION_FILE or "#{ADA_ROOT}/.angela/ada-session"
  brainPath: ADA_BRAIN.root
  brainCwd: ADA_BRAIN.cwd
  brainAlias: ADA_BRAIN.alias or 'ada'
  taskShared: process.env.TODO_SHARED or process.env.ADA_TASK_SHARED or
    config.task_lists?.shared or '/workspace/Biz/EM/Agent/ada-shared.task.md'
  allowlistPath: process.env.ADA_ALLOWLIST or config.allowlist_file or
    "#{ADA_ROOT}/allowlist.txt"
  confirmEnabled: if process.env.ADA_CONFIRM_ENABLED?
      process.env.ADA_CONFIRM_ENABLED in ['1', 'true', 'yes']
    else if config.confirm?.enabled is false
      false
    else
      true
  voiceTom: process.env.ADA_VOICE_TOM or config.voice_tom or 'michael'
  denyPhrases: config.confirm?.deny_phrases or ['belay that order']
  confirmTimeoutMs: Number(process.env.ADA_CONFIRM_TIMEOUT_MS or
    config.confirm?.timeout_ms or 60000)
  progressIntervalMs: Number(process.env.ADA_PROGRESS_INTERVAL_MS or
    config.progress?.interval_ms or 20000)
  progressCancelPrefix: process.env.ADA_PROGRESS_CANCEL or
    config.progress?.cancel_prefix or 'cancel that tool'
  progressTools: config.progress?.tools or []
  contextReserveTokens: Number(process.env.ADA_CONTEXT_RESERVE_TOKENS or
    config.context?.compact_reserve_tokens or 8000)
  listenStartSec: Number(process.env.ADA_LISTEN_TIMEOUT or 6)
  slopSec: 0.3
  maxTurns: Math.max 1, Number(process.env.ADA_MAX_TURNS or config.max_turns or 20) or 20

log = (a...) -> console.log "[#{new Date().toISOString().slice 11, 23}]", a...

# ---------------------------------------------------------------------------
# State machine + avatar socket server (JSON lines)

state = { listening: false, active: false, thinking: false, speaking: false, ear: 0, ear_t: 0 }
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
# PTT + activation gate (no conversation window — listen tool instead)

pttDown = false
pttIntervals = [] # {down, up} unix seconds, recent only
pttSquelchTimer = null
PTT_HOLD_MS = 250 # must match avatar short-click threshold
pttBuf = createTranscriptBuf()
listenSession = null
listenEpoch = 0
earJobs = []
earPumping = false
gathering = false
gatherCancelled = false
gatherBuf = createTranscriptBuf()
lastUnaddressed = null
micSpeaking = false
adaHarness = null
adaSession = null

isActivelyListening = ->
  Boolean pttDown or listenSession? or gathering or earJobs.some (j) -> not j.cancelled

# Shader rec/fuse:
#   0 off
#   1 armed (ear open, no clock — Ada may still be talking)
#   2 start-timeout running
#   3 start-timeout ended empty
#   4 finish-timeout running
#   5 finish-timeout ended empty
#   6 got utterance (she was already quiet)
#   7 barge-in interrupt (she was still talking)
setEar = (phase, remain = 0, total = 0) ->
  frac = 0
  if phase > 0
    frac = if total > 0 then Math.max(0, Math.min(1, remain / total)) else 1
  frac = Math.round(frac * 50) / 50
  setState ear: phase, ear_t: frac

earFlashUntil = 0
flashEar = (phase, ms = 480) ->
  setEar phase
  deadline = Date.now() + ms
  earFlashUntil = deadline
  setTimeout ->
    return unless earFlashUntil is deadline
    setEar 0 unless listenSession? or pttDown or gathering
  , ms

onAvatarEvent = (ev) ->
  switch ev.ev
    when 'ptt'
      now = Date.now() / 1000
      if ev.down and not pttDown
        pttDown = true
        pttBuf = createTranscriptBuf()
        pttIntervals.push { down: now, up: null }
        setState active: true
        listenSession?.setHeld true
        # Delay listen-on until this is a real hold. A short click also sends
        # ptt down/up; playing squelch here made cancel play both sfx.
        clearTimeout pttSquelchTimer if pttSquelchTimer
        pttSquelchTimer = setTimeout ->
          pttSquelchTimer = null
          if pttDown
            sfx 'squelch-on'
            setEar 1
        , PTT_HOLD_MS
      else if not ev.down and pttDown
        held = pttSquelchTimer is null
        clearTimeout pttSquelchTimer if pttSquelchTimer
        pttSquelchTimer = null
        pttDown = false
        pttIntervals.at(-1).up = now
        pttIntervals.shift() while pttIntervals.length > 8
        listenSession?.setHeld false
        # Hold release: listen-off. Short click: click handler plays it once.
        sfx 'click-off' if held
        text = snapshotText pttBuf
        pttBuf = createTranscriptBuf()
        # Walkie-talkie: LMB-up is end-of-utterance. Do not let VAD or
        # listen start/finish clocks commit while the button is down.
        if held and listenSession?
          had = Boolean snapshotText listenSession.buf
          listenSession.commit()
          pttIntervals.at(-1).committed = true if had
        else if held and text
          pttIntervals.at(-1).committed = true
          runTurn { text, t_end: now }, 'ptt'
        else
          maybeIdle()
    when 'click'
      if listenSession?
        log 'click: cancel listen'
        listenSession.cancel 'click'
        sfx 'click-off'
      else if gathering
        log 'click: cancel wake gathering'
        gatherCancelled = true
        gathering = false
        setEar 0
        setState active: false
        sfx 'click-off'
      else
        cancelAll 'click'
    when 'say'
      # External clients (`ada voice <text>`): TTS + captions only.
      text = String(ev.text or '').trim()
      if text
        log "say (external): #{text.slice(0, 120)}"
        sentences = text.split(/(?<=[.!?…])\s+/).filter (s) -> s.trim()
        for s, i in sentences
          speaker.enqueue s, null, (if i is 0 then 'interrupt' else 'enqueue')
    when 'quit'
      log 'avatar quit'

activationGate = (utt) ->
  SLOP = CFG.slopSec
  return 'ptt' if pttDown
  if utt.t_start and utt.t_end
    for iv in pttIntervals
      up = iv.up ? Date.now() / 1000
      return 'ptt' if iv.down <= utt.t_end + SLOP and up >= utt.t_start - SLOP
  return 'wake' if CFG.wake.test utt.text
  null

# `active` is only PTT-hold / listen-tool / wake-gather — never leftover
# thinking. PTT-up used to skip clearing while currentTurn was set, so the
# orb stayed "engaged" through a long completion and looked like listening.
syncActive = ->
  engaged = pttDown or listenSession? or gathering
  setState active: engaged
  unless engaged or Date.now() < earFlashUntil or
      earJobs.some (j) -> j.started and not j.cancelled
    setEar 0

maybeIdle = syncActive

# ---------------------------------------------------------------------------
# sfx feedback (borrowed from /workspace/whisper's proven set)

sfx = (name) ->
  path = "#{CFG.sfxDir}#{name}.wav"
  spawn 'paplay', [path] if existsSync path # fire and forget

sfxAwait = (name) ->
  path = "#{CFG.sfxDir}#{name}.wav"
  return unless existsSync path
  child = spawn 'paplay', [path]
  try
    await child.promise
  catch e then log "sfx #{name}: #{e.message}"

# ---------------------------------------------------------------------------
# presence-voice speaker: one in-flight request at a time serializes our
# sentence queue; the daemon's FIFO speech channel makes them gapless.
#
# Playback tracking lives on this object (not bare vars) so CoffeeScript
# closures mutate the same state — bare `playbackPending = 0` inside
# stopSpeech/event handlers compiled to shadowed locals, so the ear
# thought she was silent at TTS enqueue-ACK and fired listen-on too early.

voicePlay =
  speaking: false
  eventsLive: false
  suppressEnd: false

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

  # Closed caption with no TTS / speaking-state. Tool-status lines use this
  # so the avatar shows the last call without interrupting the conversation.
  caption: (text, who = 'ada') ->
    clean = String(text or '').replace(/[\t\n]+/g, ' ').trim()
    broadcast { ev: 'caption', who, text: clean }

  busy: -> @pumping or @queue.length > 0

  waitIdle: ->
    new Promise (resolve) =>
      tick = =>
        if @busy() then setTimeout tick, 40 else resolve()
      tick()

  clear: ->
    @queue.length = 0
    broadcast { ev: 'caption', who: 'ada', text: '' }

  pump: ->
    return if @pumping
    @pumping = true
    # True if any dequeued item belonged to a real dialogue turn (wake/PTT).
    # External `ada voice` / {ev:'say'} enqueues with turn=null — TTS only.
    spokeForDialogue = false
    try
      while @queue.length
        { text, turn, schedule } = @queue.shift()
        continue if turn?.cancelled
        spokeForDialogue = true if turn?
        setState speaking: true
        # Closed captions on the avatar: one line per spoken sentence.
        broadcast { ev: 'caption', who: 'ada', text }
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
      broadcast { ev: 'caption', who: 'ada', text: '' } unless @queue.length
      maybeIdle() unless listenSession or gathering or pttDown

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
  voicePlay.suppressEnd = true
  voicePlay.speaking = false
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
# Turn engine (tools live on Angela MCP — back/mcp/home + brain + todo)


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
  You are Ada, a spoken-voice companion and coach on Mike's home PC.
  Your replies are read aloud by text-to-speech, so: be conversational and
  concise (usually one or two short sentences), never use markdown, bullet
  points, emoji, or headings, and spell things the way they should be
  spoken. You hear the user through an always-on microphone; transcripts
  may contain small transcription errors — infer the intent.
  Be genuinely helpful, not performatively helpful. Skip filler like
  "great question" or "I'd be happy to help" — just help. Prefer tools
  over empty promises: if you say you will remember or look something up,
  call the tool in this turn.
  You can control the home with tools. There are two independently
  controllable lights: the desk lamp (desk_light) and the PC tower lights
  (pc_light_color; chassis LED strip and GPU RGB together). When the user
  says "lights" (plural) or does not name a specific light, apply the
  request to BOTH lights. You can manage alarms on Mike's Google Pixel
  Clock app with alarm__create, alarm__list, alarm__update,
  alarm__delete, alarm__show, alarm__snooze, and timers with
  timer__create, timer__dismiss, timer__show. Convert spoken times to
  24-hour hour (0-23) and minute (0-59); e.g. "8am" is hour=8 minute=0,
  "8:30pm" is hour=20 minute=30. Timer length is seconds (5 minutes is
  300). Prefer matching existing alarms by label when deleting or
  updating. alarm__list only reports the next scheduled alarm (Clock has
  no list intent). alarm__snooze only affects a currently ringing alarm.
  You may call several tools in one turn when a result tells you to
  continue — especially a brain tool `advice:` field, or an empty
  retrieval. Do not stop at the first empty search. You can also launch
  desktop apps by their program name (run_application, e.g. audacity, discord), run
  predefined activity commands (run_activity_command), and control media
  playback and system volume like keyboard media keys (media_control).
  If asked to look something up or do something on a website, delegate the
  whole task to control_browser in one call (it can see and drive my
  actual browser: navigate, read pages, click, fill forms) rather than
  trying to guess at browser tools yourself.
  Long-term memory is on disk via brain tools — you do not remember
  across restarts unless a write succeeds. When Mike says remember / do
  not forget / states a lasting preference: you MUST call
  brain__put_entity in this turn BEFORE saying you remembered. Prefer
  stable slugs (e.g. Note/favorite-color). For recall use brain__search,
  brain__think, or brain__ontology (follow any advice: in the tool
  result; do not invent). Prefer brain__get_entity when you know the
  slug. Person ids are first-initial + last name
  lowercased (Mike Smullin is Person/msmullin). If older chat was trimmed
  for length, recover with brain tools or ask Mike.
  Priorities live in todo__next, todo__tree, todo__view, todo__take,
  todo__release, todo__upsert. When Mike asks what to do next, call
  todo__next — do not invent tasks.
  After you ask a question or otherwise expect a spoken reply (knock-knock
  setup, "ready?", a choice), you MUST call listen in that same turn as a
  tool call — do not only think about calling it, and do not end the turn
  on spoken text alone. timeout is seconds to wait for him to start
  speaking (default 6). The listen tool result is a status note, not Mike's
  words. His utterance follows as the next user message — reply to that.
  Do not call listen if the exchange is finished.
  Do not pull work-laptop secrets into chat. If the user is just talking,
  just talk back — do not use tools.
  '''

SYSTEM_PROMPT = BASE_PROMPT + loadSoul()

currentTurn = null
turnCounter = 0
turnSplitter = null

lastCompletion = (result) ->
  choice = result?.choices?[0]
  finish: String(choice?.finish_reason or result?.finish_reason or '')
  content: String(choice?.message?.content or '')

# After a freeform stop: if the last spoken reply asked a question, open the
# ear without waiting for a listen tool call. STT becomes a new user turn
# (session.run already returned — unlike the listen tool's in-flight inject).
maybeAutoListen = (turn, result) ->
  return if turn.cancelled or pttDown or gathering
  # Listen tool already opened the ear this turn (`?` + listen) — don't arm twice.
  return if turn.hadListen or listenSession? or earJobs.length
  { finish, content } = lastCompletion result
  return unless finish.toLowerCase() is 'stop'
  return unless /[?？]/.test content
  log "auto-listen: last reply contains ? (finish=#{finish})"
  try
    heard = await beginListen CFG.listenStartSec, asUser: true, turn: turn
  catch e
    log "auto-listen: #{e.message}"
    return
  text = String(heard?.text or '').trim()
  return unless heard?.ok and text
  return if heard.injected # listen tool already put STT on this run
  return if turn.cancelled or currentTurn?
  await runTurn { text, t_end: Date.now() / 1000 }, 'listen'

runTurn = (utt, gate) ->
  # barge-in: a new passing utterance cancels whatever is pending/speaking —
  # clear our queue AND silence the daemon immediately (don't wait for the
  # reply's first sentence to interrupt)
  listenEpoch++
  if currentTurn
    currentTurn.cancelled = true
    try
      await adaSession?.abort 'barge-in'
    catch e then log "abort: #{e.message}"
  stopSpeech()
  speaker.clear()

  turn =
    id: ++turnCounter
    cancelled: false
    hadListen: false
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
  gathering = false
  setEar 0 unless listenSession?
  setState thinking: true, active: pttDown
  log "turn #{turn.id} [#{gate}]: #{utt.text}"

  splitter = new SentenceSplitter (sentence) ->
    return if turn.cancelled
    # opening sentence interrupts (kills any stale speech a cancelled turn
    # managed to get in flight); the rest of the reply enqueues gapless
    first = turn.lat.firstSentence is null
    turn.lat.firstSentence = performance.now() if first
    speaker.enqueue sentence, turn, (if first then 'interrupt' else 'enqueue')
  turnSplitter = splitter

  runResult = null
  try
    try
      adaHarness?.policy?.setAllowlist readFileSync(CFG.allowlistPath, 'utf8')
    catch e then null
    agent = adaSession?.agent
    if agent
      n = compactContextWindow agent, reserveTokens: CFG.contextReserveTokens
      log "turn #{turn.id}: compacted #{n} lines" if n
    runResult = await adaSession.run prompt: utt.text
  catch e
    unless turn.cancelled or e?.aborted or /listen-empty/.test(e?.message or '')
      log "turn #{turn.id} error: #{e.message}"
      speaker.enqueue 'Sorry, something went wrong.', turn
    else
      log "turn #{turn.id} aborted: #{e.message}"
  splitter.flush()
  turnSplitter = null if turnSplitter is splitter

  if currentTurn is turn
    currentTurn = null
    setState thinking: false
    maybeIdle()

  # latency report (plan §7)
  l = turn.lat
  ms = (v) -> if v is null then ' n/a' else "#{Math.round v - l.start}ms"
  eouToArrive = if l.eou then "#{Math.round l.utteranceArrived - l.eou}ms" else 'n/a'
  log "turn #{turn.id} latency: eou→utterance=#{eouToArrive} " +
    "utterance→first_token=#{ms l.firstToken} first_sentence=#{ms l.firstSentence} " +
    "speech_done=#{ms l.lastAudioDone}#{if turn.cancelled then ' (cancelled)' else ''}"

  await maybeAutoListen turn, runResult

cancelAll = (reason) ->
  # Avatar short-click: belay every remaining Tom challenge (current + queue).
  if tomIsWaiting() or reason is 'click'
    if tomDenyAllPending(reason or 'click')
      log "tom: denied all pending (#{reason or 'click'}) — as belay that order"
      try
        broadcast { ev: 'caption', who: 'tom', text: '' }
      catch e then null
  listenEpoch++
  if currentTurn
    log "cancel (#{reason}): turn #{currentTurn.id}"
    currentTurn.cancelled = true
    currentTurn = null
  speaker.clear()
  stopSpeech() # silence anything already playing, whisper-style cancel
  sfx 'click-off'
  try
    adaSession?.abort reason
  catch e then null
  setState thinking: false, active: pttDown
  maybeIdle()

# ---------------------------------------------------------------------------
# perception-voice words stream (framed JSON: 4-byte BE length + payload)

frameJson = (obj) ->
  payload = Buffer.from JSON.stringify(obj), 'utf8'
  header = Buffer.alloc 4
  header.writeUInt32BE payload.length
  Buffer.concat [header, payload]

onLevelsFrame = (frame) ->
  micSpeaking = Boolean frame?.speaking
  listenSession?.tickLevels frame
  if gathering
    feedPartial gatherBuf, gatherBuf.lastPartial, micSpeaking

onWordsEvent = (msg) ->
  if msg.ev is 'partial'
    if listenSession?
      listenSession.feedPartial msg.text or '', micSpeaking
      return
    if pttDown
      feedPartial pttBuf, msg.text or '', micSpeaking
      return
    if tomIsWaiting()
      setState active: true
      return
    wakeHit = CFG.wake.test(msg.text or '')
    if wakeHit and not currentTurn and not pttDown
      unless gathering
        gathering = true
        gatherCancelled = false
        gatherBuf = createTranscriptBuf()
        setState active: true
        setEar 1
      feedPartial gatherBuf, msg.text or '', micSpeaking
    else if gathering
      feedPartial gatherBuf, msg.text or '', micSpeaking
    else if not state.active and (pttDown or wakeHit)
      setState active: true
    return
  if msg.ev is 'utterance'
    if tomIsWaiting()
      log "tom heard: #{msg.text}"
      tomFeedUtterance msg.text or ''
      return
    if progressIsWaiting()
      progressFeedUtterance msg.text or ''
      return
    if listenSession?
      listenSession.feedUtterance msg.text or ''
      return
    # PTT hold: VAD may emit utterances (0.6s silence) but LMB-up is
    # end-of-utterance. Buffer until release so a pause does not start
    # a turn mid-hold.
    if pttDown
      gatherFeedUtterance pttBuf, msg.text or ''
      return
    # Late STT for a hold we already committed (VAD finalized after LMB-up).
    if msg.t_start?
      tEnd = msg.t_end or Date.now() / 1000
      for iv in pttIntervals when iv.committed
        up = iv.up ? Date.now() / 1000
        if iv.down <= tEnd + CFG.slopSec and up >= msg.t_start - CFG.slopSec
          log "(ptt echo) #{msg.text}"
          return
    if gathering and gatherCancelled
      log "(cancelled gather) #{msg.text}"
      gathering = false
      gatherCancelled = false
      maybeIdle()
      return
    gathering = false
    setEar 0 unless listenSession?
    gate = activationGate msg
    unless gate
      lastUnaddressed =
        text: msg.text
        t_end: msg.t_end or Date.now() / 1000
      log "(unaddressed) #{msg.text}"
      maybeIdle()
      return
    text = String(msg.text or '')
    if lastUnaddressed?.t_end? and msg.t_start?
      if msg.t_start - lastUnaddressed.t_end <= CFG.slopSec
        extra = String(lastUnaddressed.text or '').trim()
        text = "#{extra}\n#{text}" if extra
    lastUnaddressed = null
    gathered = snapshotText gatherBuf
    if gathered and gathered.length > text.length
      text = gathered
    gatherBuf = createTranscriptBuf()
    runTurn { msg..., text }, gate

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

connectPresenceEvents = (isRetry = false) ->
  sock = net.connect CFG.presenceSock, ->
    sock.write 'subscribe\tevents\n'
  acc = ''
  acked = false
  sock.on 'data', (d) ->
    acc += d.toString()
    loop
      idx = acc.indexOf '\n'
      break if idx < 0
      line = acc.slice(0, idx).trim()
      acc = acc.slice idx + 1
      unless acked
        acked = true
        unless line is 'OK'
          log "presence events subscribe rejected: #{line}"
          sock.end()
        else
          log 'subscribed to presence-voice events'
        continue
      continue unless line
      try
        msg = JSON.parse line
      catch e then continue
      if msg.ev is 'speak-start'
        voicePlay.eventsLive = true
        voicePlay.suppressEnd = false
        voicePlay.speaking = true
      else if msg.ev is 'speak-end'
        voicePlay.eventsLive = true
        voicePlay.speaking = false unless voicePlay.suppressEnd
  sock.on 'error', (e) ->
    log "presence events: #{e.message}" unless isRetry
  sock.on 'close', ->
    voicePlay.eventsLive = false
    voicePlay.speaking = false
    log 'presence events lost; reconnecting…' if acked
    setTimeout (-> connectPresenceEvents true), 1000

# ---------------------------------------------------------------------------
# listen tool socket (home MCP shim → this waiter)
#
# One in-flight ear at a time. Extra listen requests (listen tool + `?`
# auto-listen, or two listen tool calls) collapse onto that one session —
# all waiters share the result. STT is delivered once.

sleep = (ms) -> new Promise (r) -> setTimeout r, ms

# Pump still sending TTS, or presence-voice still playing. Do not use
# voicePlay.pending here: a missed speak-end leaves pending > 0 forever
# and the listen-on chime never fires.
isVocalizing = ->
  speaker.busy() or voicePlay.speaking

settleEar = (job, result) ->
  return if job.settled
  job.settled = true
  for w in job.waiters or []
    w.resolve result

# Quiet = not pumping and not playing, stable for QUIET_MS (covers the
# enqueue-ACK → speak-start gap and tiny gaps between FIFO sentences).
QUIET_MS = 180
waitVocalization = (epoch) ->
  turnSplitter?.flush()
  quietSince = null
  loop
    return false if epoch isnt listenEpoch
    if isVocalizing()
      quietSince = null
    else
      quietSince ?= Date.now()
      if Date.now() - quietSince >= QUIET_MS
        return true
    await sleep 40

# Stream reducer: at most one ear job. A new request joins the live or
# queued session instead of opening a second.
attachEar = (waiter) ->
  live = earJobs.find (j) -> not j.cancelled and not j.settled
  if live?
    log "ear: reducer — join #{if live.started then 'in-flight' else 'queued'} listen (#{live.waiters.length + 1} waiters)"
    live.waiters.push waiter
    if waiter.timeoutSec > (live.timeoutSec or 0)
      live.timeoutSec = waiter.timeoutSec
    currentTurn?.hadListen = true
    waiter.opts.turn?.hadListen = true
    return
  job =
    timeoutSec: waiter.timeoutSec
    opts: waiter.opts or {}
    waiters: [waiter]
    started: false
    cancelled: false
    settled: false
    epoch: listenEpoch
  earJobs.push job
  pumpEar()
  return

pumpEar = ->
  return if earPumping
  earPumping = true
  try
    while earJobs.length
      job = earJobs[0]
      if job.cancelled
        earJobs.shift()
        continue
      asUserOnly = (job.waiters or []).every (w) -> w.opts.asUser
      turn = job.opts.turn or job.waiters?[0]?.opts?.turn
      if asUserOnly and (turn?.cancelled or currentTurn?)
        settleEar job, { ok: false, reason: 'cancelled', text: '' }
        earJobs.shift()
        continue
      job.started = true
      try
        settleEar job, await armEar job
      catch e
        settleEar job, { ok: false, reason: 'error', text: e.message }
      earJobs.shift()
  finally
    earPumping = false

armEar = (job) ->
  if job.cancelled or job.epoch isnt listenEpoch
    return { ok: false, reason: 'cancelled', text: '' }
  currentTurn?.hadListen = true
  for w in job.waiters or []
    w.opts.turn?.hadListen = true
  job.opts = job.waiters?[0]?.opts or job.opts or {}
  turnSplitter?.flush()
  log "ear: armed (parallel with vocalization, #{job.waiters.length} waiter#{if job.waiters.length is 1 then '' else 's'})"
  sess = createListenSession
    timeoutSec: job.timeoutSec
    log: log
    onTick: (s) ->
      h = s.hud()
      setEar h.phase, h.remain, h.total
    onStart: ->
      setState active: true
      setEar 1
    onEnd: (s, result) ->
      listenSession = null if listenSession is s
      text = String(result?.text or '').trim()
      barged = Boolean(result?.ok and text and isVocalizing())
      if barged
        log 'ear: barge-in — stop speech, take utterance'
        stopSpeech()
        speaker.clear()
        result.reason = 'interrupt'
      if result?.ok and text
        flashEar if barged then 7 else 6
      else if result?.reason is 'timeout' and s.heardWords
        flashEar 5
      else if result?.reason is 'timeout'
        flashEar 3
      else
        setEar 0
      maybeIdle()
      # One STT delivery. Prefer in-run inject if any waiter is the listen
      # tool; asUser waiters then skip opening a second turn.
      inject = (job.waiters or []).some (w) -> not w.opts.asUser
      if result?.ok and text and inject
        try
          adaSession?.agent?.enqueueUserAfterTools? text
          result.injected = true
        catch e
          log "listen enqueue user: #{e.message}"
      else if inject and not (result?.ok and text)
        # Tool result still goes back; do not start another completion.
        try
          adaSession?.agent?.abort 'listen-empty'
        catch e then null
      log "listen done ok=#{result.ok} reason=#{result.reason or ''} #{text.slice 0, 80}"
  listenSession = sess
  sess.setHeld true if pttDown
  # Chime + start-timeout wait for her playback to actually end. The ear
  # is already capturing STT so a barge-in can land while she talks.
  do ->
    ok = await waitVocalization job.epoch
    return unless ok and not sess.done and not job.cancelled
    sess.armFromBufferIfAny()
    if sess.heardWords
      log 'ear: vocalization done — user already speaking, skip chime/start clock'
      return
    log 'ear: vocalization done — listen-on then start timeout'
    await sfxAwait 'listen-on'
    return if sess.done or job.cancelled or job.epoch isnt listenEpoch
    sess.armFromBufferIfAny()
    return if sess.heardWords
    sess.releaseStartClock()
  sess.promise

beginListen = (timeoutSec, opts = {}) ->
  new Promise (resolve) ->
    attachEar {
      timeoutSec: timeoutSec or CFG.listenStartSec
      opts
      resolve
    }

startVoiceSock = ->
  try unlinkSync CFG.voiceSock if existsSync CFG.voiceSock
  catch e then null
  server = net.createServer (sock) ->
    acc = ''
    sock.on 'data', (buf) ->
      acc += buf.toString()
      while (idx = acc.indexOf '\n') >= 0
        line = acc.slice(0, idx).trim()
        acc = acc.slice idx + 1
        continue unless line
        try
          req = JSON.parse line
        catch e
          sock.write JSON.stringify({ ok: false, reason: 'bad-json' }) + '\n'
          continue
        if req.cmd is 'listen'
          try
            result = await beginListen req.timeout
          catch e
            result = { ok: false, reason: 'error', text: e.message }
          try sock.write JSON.stringify(result) + '\n'
          catch e then null
        else
          sock.write JSON.stringify({ ok: false, reason: 'unknown-cmd' }) + '\n'
    sock.on 'error', -> null
  server.listen CFG.voiceSock
  log "voice sock listening on unix://#{CFG.voiceSock}"

readAllowlistText = ->
  try
    readFileSync CFG.allowlistPath, 'utf8'
  catch e
    ''

tomApprover = (req) ->
  unless CFG.confirmEnabled
    return 'deny'
  wave = joinToolWave()
  registerToolWaveGate wave, true
  speaker.clear()
  stopSpeech()
  tom = await runTomInWave wave,
    toolName: req.tool
    args: req.args
    risk: 'medium'
    speakOnce: speakOnce
    stopSpeech: stopSpeech
    broadcast: broadcast
    voiceTom: CFG.voiceTom
    denyPhrases: CFG.denyPhrases
    timeoutMs: CFG.confirmTimeoutMs
    log: log
  if tom.approved then 'allow' else 'deny'

persistSessionId = (id) ->
  try
    mkdirSync dirname(CFG.sessionFile), recursive: true
    writeFileSync CFG.sessionFile, "#{id}\n"
  catch e
    log "session id write failed: #{e.message}"

openOrCreateSession = (harness) ->
  id = null
  try
    id = readFileSync(CFG.sessionFile, 'utf8').trim() if existsSync CFG.sessionFile
  catch e then null
  if id
    try
      sess = await harness.session.open id
      log "resumed angela session #{id}"
      return sess
    catch e
      log "session open failed (#{e.message}); creating new"
  sess = await harness.session.create title: 'ada', agent: 'ada'
  persistSessionId sess.id
  log "created angela session #{sess.id}"
  sess

onHarnessDelta = (d, meta) ->
  turn = currentTurn
  return unless turn and not turn.cancelled
  return if meta?.channel is 'reasoning'
  return unless d
  turn.lat.firstToken = performance.now() if turn.lat.firstToken is null
  turn.reply += d
  turnSplitter?.push d

# ---------------------------------------------------------------------------
# startup

main = ->
  acquireInstanceLock()
  # Shared gate across every Agent.run() call, including nested ones: a turn
  # that calls control_browser holds its own slot AND the sub-agent's for the
  # whole delegated task, so 4 barely covers one turn + one barge-in. Bumped
  # to 6 for headroom (see agl's Agent.default.concurrency / _acquireRunSlot).
  Agent.default.concurrency = 6

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

  # optional: the browser sub-agent, only if mcp-zen is running
  await initBrowserAgent()

  # long-term memory: Ada's own `brain mcp` over stdio, pointed at the `ada`
  # `brain use` database. Starts `brain server` for that db if it isn't up.
  # Failure is non-fatal — home tools still work; the next turn retries.
  brainOk = await ensureBrainMcp
    cwd: CFG.brainCwd
    root: CFG.brainPath
    alias: CFG.brainAlias
  log if brainOk then "brain mcp ready (#{CFG.brainAlias} #{CFG.brainPath})" else 'brain mcp unavailable'

  todoOk = await ensureTodoMcp shared: CFG.taskShared
  log if todoOk then "todo mcp ready (#{CFG.taskShared})" else 'todo mcp unavailable'

  bun = process.execPath
  mcp = [
    name: 'home'
    prefix: false
    command: bun
    args: [join ADA_ROOT, 'back/mcp/home/server.coffee']
    cwd: join ADA_ROOT, 'back'
    env:
      ADA_ACTIVITY_DIR: CFG.activityDir
      ADA_VOICE_SOCK: CFG.voiceSock
      ADA_MODEL: CFG.model
      FAV_LOCAL_LLM: CFG.model
  ]
  mcp.push
    name: 'brain'
    command: process.env.ADA_BRAIN_CMD or 'brain'
    args: ['--use', CFG.brainAlias, 'mcp']
    cwd: CFG.brainCwd
  if todoOk
    mcp.push
      name: 'todo'
      command: process.env.ADA_TODO_CMD or 'todo'
      args: ['mcp']
      env:
        TODO_SHARED: CFG.taskShared
        TODO_DEFAULT_LIST: 'shared'

  adaHarness = await Angela.create
    projectRoot: ADA_ROOT
    model: CFG.model
    system: SYSTEM_PROMPT
    retain_history: true
    stream: true
    parallel_tools: true
    reasoning_effort: 'low'
    policyMode: 'ask'
    allowlist: readAllowlistText()
    onApproval: tomApprover
    mcp: mcp
    persistSessions: true
    on_delta: onHarnessDelta
    max_turns: CFG.maxTurns

  adaSession = await openOrCreateSession adaHarness
  await adaSession.listToolCatalog()
  wrapToolsForUx adaSession.agent if adaSession.agent
  log "angela tools: #{Object.keys(adaSession.agent?.tools or {}).join ', '}"

  startAvatarServer()
  startVoiceSock()
  connectWords()
  connectLevels CFG.perceptionSock, onLevelsFrame, log
  connectPresenceEvents()
  log "ada-back ready (voice=#{CFG.voice} tom=#{CFG.voiceTom} confirm=#{CFG.confirmEnabled} " +
    "model=#{CFG.model} max_turns=#{CFG.maxTurns} wake=#{CFG.wake} session=#{adaSession.id} " +
    "brain=#{if brainOk then 'on' else 'off'} todo=#{if todoOk then 'on' else 'off'})"

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
    try
      unlinkSync CFG.voiceSock if existsSync CFG.voiceSock
    catch e then null
    try
      adaHarness?.close?()
    catch e then null
    releaseInstanceLock()
    process.exit 0
process.on 'exit', releaseInstanceLock

await main()
