# Progress narrator (PLAN2 M5): speak status while a long tool runs;
# cancel via spoken phrase (default "cancel that tool").
import { normalizeSpeech } from './petname.coffee'

# Tools that get a progress ticker by default (long / external).
DEFAULT_LONG_TOOLS = [
  'control_browser'
  'run_activity_command'
  'run_application'
]

active = null # { toolName, started, cancelPrefix, resolveCancel, timer, speak, ... }

export isWaiting = -> active?

export isLongTool = (toolName, extra = []) ->
  name = String(toolName or '')
  return true if name in DEFAULT_LONG_TOOLS
  return true if name in (extra or [])
  false

matchesCancel = (spoken, cancelPrefix) ->
  s = normalizeSpeech spoken
  p = normalizeSpeech cancelPrefix or 'cancel that tool'
  return false unless p
  s is p or s.startsWith(p) or s.includes(p)

# Feed STT while a long tool is in flight. Returns true if consumed (cancel or hold).
export feedUtterance = (text) ->
  return false unless active
  if matchesCancel text, active.cancelPrefix
    active.log? "progress cancel heard: #{normalizeSpeech text}"
    doCancel active, 'user'
    return true
  # Hold the utterance so Ada does not start a parallel turn mid-tool.
  active.log? "progress holding speech (say \"#{active.cancelPrefix}\" to abort): #{normalizeSpeech text}"
  true

doCancel = (job, reason) ->
  return unless active is job
  job.cancelled = true
  try job.kill?() catch e then null
  clearInterval job.timer if job.timer
  job.timer = null
  resolve = job.resolveCancel
  active = null
  resolve? { cancelled: true, reason }

export stopProgress = ->
  return unless active
  job = active
  clearInterval job.timer if job.timer
  job.timer = null
  # Do not resolve cancelPromise as cancelled — tool finished normally.
  job.resolveCancel = null
  active = null
  try
    job.broadcast? { ev: 'caption', who: 'ada', text: '' }
  catch e then null

# Start ticker. Returns { cancelPromise, setKill, stop }.
export startProgress = ({
  toolName
  args
  intervalMs
  cancelPrefix
  speakOnce
  broadcast
  voice
  log
}) ->
  stopProgress() # only one long tool progress at a time

  started = Date.now()
  cancelPrefix = cancelPrefix or 'cancel that tool'
  intervalMs = Math.max(3000, intervalMs or 8000)

  resolveCancel = null
  cancelPromise = new Promise (r) -> resolveCancel = r

  job =
    toolName: toolName
    args: args
    started: started
    cancelPrefix: cancelPrefix
    cancelled: false
    kill: null
    timer: null
    resolveCancel: resolveCancel
    speakOnce: speakOnce
    broadcast: broadcast
    voice: voice
    log: log
    tick: 0

  active = job

  speakUpdate = (text, schedule = 'enqueue') ->
    clean = String(text or '').replace(/[\t\n]+/g, ' ').trim()
    return unless clean
    try
      broadcast? { ev: 'caption', who: 'ada', text: clean }
    catch e then null
    try
      await speakOnce voice or 'nova', clean, schedule
    catch e
      log? "progress speak failed: #{e.message}"

  # First beat after one interval (not immediately — tool just started).
  job.timer = setInterval ->
    return unless active is job
    job.tick += 1
    elapsed = Math.round (Date.now() - started) / 1000
    nextIn = Math.round intervalMs / 1000
    label = humanTool toolName, args
    msg = "Still working on #{label}. About #{elapsed} seconds so far. " +
      "Next update in #{nextIn} seconds. Say #{cancelPrefix} to stop."
    log? "progress tick #{job.tick} #{toolName} #{elapsed}s"
    # Don't await inside interval — overlap protection
    unless job.speaking
      job.speaking = true
      speakUpdate(msg, 'enqueue')
        .catch (e) -> log? "progress tick error: #{e.message}"
        .finally -> job.speaking = false
  , intervalMs

  setKill: (fn) -> job.kill = fn
  cancelPromise: cancelPromise
  isCancelled: -> job.cancelled
  stop: ->
    return unless active is job
    stopProgress()

humanTool = (toolName, args) ->
  a = args or {}
  switch toolName
    when 'control_browser' then "browser task#{if a.task then ": #{clip a.task, 60}" else ''}"
    when 'run_activity_command' then "activity #{a.id or 'command'}"
    when 'run_application' then "launching #{a.app or 'app'}"
    else toolName

clip = (s, n = 60) ->
  t = String(s or '').replace(/\s+/g, ' ').trim()
  if t.length <= n then t else t.slice(0, n - 1) + '…'
