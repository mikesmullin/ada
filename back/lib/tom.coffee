# Tom the Security Guy — confirmation microagent boundary (PLAN2 M4).
# One decision: approve or deny a gated tool call via spoken 3-word phrase.
# Voice: presence-voice preset `michael` (Kokoro am_michael). STT: next utterances.
#
# Serial presentation (one prompt at a time):
# - A single job pump runs Tom sessions. The next challenge is presented only
#   after the user approves / denies / times out / click-belays — NOT after TTS
#   finishes. Mid-narration approve still works (caption + STT arm first).
# - Parallel tools still share a wave barrier: tool *bodies* wait until every
#   Tom decision in the wave is finished.
import { randomApprovePhrase, matchesApprovePhrase, matchesDenyPhrase, normalizeSpeech } from './petname.coffee'

# Active STT wait: set while one challenge is listening.
waiter = null

# Utterances heard while session owns the mic but waiter not armed yet.
pendingSpeech = []

# Mass-deny (avatar click): remaining queue resolves denied without speaking.
tomAbortAll = null # { approved: false, reason, spoken }

# --- Serial Tom job pump (presentation queue) --------------------------------
# Advances on user reply only. At most one tomConfirm presentation at a time.
tomJobQueue = [] # { run, resolve, reject }
tomPumpRunning = false

# Parallel tool wave barrier
activeWave = null
waveSeq = 0

export isWaiting = ->
  waiter? or tomPumpRunning or tomJobQueue.length > 0

# Check/X should show only while a challenge is armed or queued — not while
# the pump is still running a tool after approve (that was sticking the UI).
export isConfirmPending = ->
  Boolean waiter or tomJobQueue.length > 0

# Avatar check/X click: resolve the live challenge the same as speech.
export decideFromClick = (approved) ->
  return false unless waiter?
  finish waiter,
    approved: Boolean approved
    reason: if approved then 'click' else 'click-deny'
    spoken: if approved then '(click approve)' else '(click deny)'
  true

# Avatar click / cancel: deny active + every remaining queued Tom.
export denyAllPending = (reason = 'click') ->
  unless isWaiting()
    return false
  result =
    approved: false
    reason: reason or 'denied'
    spoken: 'belay that order'
  tomAbortAll = result
  pendingSpeech.length = 0
  if waiter
    finish waiter, result
  # Queued jobs observe tomAbortAll when the pump reaches them (no extra speak).
  true

# Called from ada-back words stream when Tom owns listening.
export feedUtterance = (text) ->
  unless isWaiting()
    return false
  w = waiter
  unless w
    pendingSpeech.push String(text or '')
    return true
  applyUtterance w, text

applyUtterance = (w, text) ->
  w.resetTimer?()
  if matchesDenyPhrase text, w.denyPhrases
    finish w, { approved: false, reason: 'denied', spoken: text }
    return true
  if matchesApprovePhrase text, w.phrase
    finish w, { approved: true, reason: 'approved', spoken: text }
    return true
  w.onIgnored?(text)
  true

drainPending = (w) ->
  while pendingSpeech.length and waiter is w
    text = pendingSpeech.shift()
    applyUtterance w, text
    break unless waiter is w

finish = (w, result) ->
  return unless waiter is w
  clearTimeout w.timer if w.timer
  waiter = null
  pendingSpeech.length = 0
  w.resolve result

# Arm STT for one challenge. Under the serial pump there is never a second
# presentation while a waiter is live; if there is, wait until it clears.
export waitForSpokenConfirm = ({ phrase, denyPhrases, timeoutMs, onIgnored }) ->
  # Serialize arming — never start a second challenge's listen while first is open.
  while waiter?
    await delay 15
  new Promise (resolve) ->
    w = { phrase, denyPhrases, resolve, onIgnored, timer: null, resetTimer: null }
    arm = ->
      clearTimeout w.timer if w.timer
      w.timer = setTimeout ->
        finish w, { approved: false, reason: 'timeout' }
      , timeoutMs or 60000
    w.resetTimer = arm
    waiter = w
    arm()
    drainPending w

delay = (ms) -> new Promise (r) -> setTimeout r, ms

# Run jobs one at a time; next starts only after previous run() settles
# (which is after user decision — not after TTS).
enqueueTomJob = (run) ->
  new Promise (resolve, reject) ->
    tomJobQueue.push { run, resolve, reject }
    pumpTomJobs()

pumpTomJobs = ->
  return if tomPumpRunning
  return unless tomJobQueue.length
  tomPumpRunning = true
  job = tomJobQueue.shift()
  Promise.resolve()
    .then -> job.run()
    .then (result) -> job.resolve result
    .catch (err) -> job.reject err
    .finally ->
      tomPumpRunning = false
      if tomJobQueue.length is 0 and not waiter?
        tomAbortAll = null
      # Always continue on next tick so the previous session fully unwinds.
      setTimeout pumpTomJobs, 0

# ---------------------------------------------------------------------------
# Parallel tool wave barrier
# ---------------------------------------------------------------------------

newWave = ->
  waveSeq += 1
  execResolve = null
  {
    id: waveSeq
    members: 0
    checked: 0
    tomNeeded: 0
    tomFinished: 0
    tomStarted: 0
    sealed: false
    execP: new Promise (r) -> execResolve = r
    execResolve: execResolve
  }

export joinToolWave = ->
  unless activeWave and not activeWave.sealed
    activeWave = newWave()
  w = activeWave
  w.members += 1
  w

export registerToolWaveGate = (w, needsTom) ->
  if needsTom
    w.tomNeeded += 1
  w.checked += 1
  if w.checked >= w.members
    w.sealed = true
    if activeWave is w
      activeWave = null
    if w.tomNeeded is 0
      w.execResolve()

markTomFinished = (w) ->
  w.tomFinished += 1
  if w.tomFinished >= w.tomNeeded and w.tomNeeded > 0
    w.execResolve()

export waitToolWaveExec = (w) -> w.execP

# One full Tom session per tool call, serialized on the presentation pump.
# Wave still waits for ALL decisions before any tool body runs.
export runTomInWave = (w, opts) ->
  decision = await enqueueTomJob ->
    w.tomStarted = (w.tomStarted or 0) + 1
    if tomAbortAll
      d = Object.assign {}, tomAbortAll
      opts.log? "tom abort (#{d.reason}): skip #{opts.toolName} " +
        "(#{w.tomStarted}/#{w.tomNeeded})"
      markTomFinished w
      return d
    sessionOpts = Object.assign {}, opts,
      tomIndex: w.tomStarted
      tomTotal: w.tomNeeded
    d = null
    try
      d = await tomConfirm sessionOpts
    catch e
      d = { approved: false, reason: 'error', error: e.message }
    if tomAbortAll and d?.approved
      d = Object.assign {}, tomAbortAll
    markTomFinished w
    d
  await w.execP
  decision

export waitWaveThenRun = (w) ->
  await w.execP

# ---------------------------------------------------------------------------
# One Tom presentation (single caption + phrase + listen)
# ---------------------------------------------------------------------------

# 1) Arm STT + show ONE caption immediately.
# 2) Speak in background (user may approve before TTS ends).
# 3) On decision: cut audio, clear caption, return — pump starts next Tom.
export tomConfirm = ({
  toolName
  args
  risk
  speakOnce
  stopSpeech
  broadcast
  voiceTom
  denyPhrases
  timeoutMs
  log
  speakSchedule
  tomIndex
  tomTotal
  onWaiting
}) ->
  if tomAbortAll
    return Object.assign {}, tomAbortAll, phrase: null

  phrase = randomApprovePhrase()
  summary = summarizeTool toolName, args
  ord = ''
  if tomTotal? and tomTotal > 1 and tomIndex?
    ord = "Request #{tomIndex} of #{tomTotal}. "
  denyLine = denyPhrases?[0] or 'belay that order'
  challenge = "#{ord}#{summary} " +
    "To approve, say exactly: #{phrase}. " +
    "To deny, say: #{denyLine}."

  log? "tom challenge [#{risk}] #{toolName} (#{tomIndex or 1}/#{tomTotal or 1}): " +
    "approve=\"#{phrase}\" summary=#{JSON.stringify summary}"

  repromptBusy = false
  lastReprompt = 0
  MIN_REPROMPT_MS = 2500
  schedule = speakSchedule or 'interrupt'
  decided = false

  showCaption = (text) ->
    try
      # who=tom: avatar replaces prior Tom line (not stacked) — see avatar.zig
      broadcast? { ev: 'caption', who: 'tom', text: text ? '' }
    catch e then null

  cutTomAudio = ->
    try
      if stopSpeech?
        stopSpeech()
      else if speakOnce?
        await speakOnce voiceTom or 'michael', '', 'interrupt'
    catch e
      log? "tom cut audio failed: #{e.message}"

  speakChallenge = (sched = schedule) ->
    return if decided
    # Re-show caption on every speak (including re-prompt after a non-answer).
    # who=tom replaces the prior Tom line on the avatar — no stacking.
    showCaption challenge
    try
      await speakOnce voiceTom or 'michael', challenge, sched
    catch e
      unless decided
        log? "tom speak failed: #{e.message}"

  # Arm listen first — only after this is the active challenge.
  confirmP = waitForSpokenConfirm
    phrase: phrase
    denyPhrases: denyPhrases or ['belay that order']
    timeoutMs: timeoutMs or 60000
    onIgnored: (text) ->
      return if decided
      log? "tom ignored utterance: #{normalizeSpeech text} — re-prompting"
      now = Date.now()
      return if repromptBusy
      return if now - lastReprompt < MIN_REPROMPT_MS
      repromptBusy = true
      lastReprompt = now
      speakChallenge('interrupt')
        .catch (e) -> log? "tom re-prompt failed: #{e.message}"
        .finally -> repromptBusy = false

  # Narration is non-blocking; decision is user reply.
  # First speak also paints the caption via speakChallenge.
  speakP = speakChallenge(schedule).catch (e) ->
    log? "tom speak error: #{e.message}"
    null

  try onWaiting?(true)
  catch e then null
  result = await confirmP
  decided = true
  try onWaiting?(false)
  catch e then null

  await cutTomAudio()
  speakP.catch(-> null)
  showCaption ''

  log? "tom result: #{result.reason} approved=#{result.approved}"
  result.phrase = phrase
  result

# ---------------------------------------------------------------------------
# Per-call summaries (never a shared microagent across tools)
# ---------------------------------------------------------------------------

summarizeTool = (toolName, args) ->
  a = args or {}
  switch toolName
    when 'remember_fact'
      fact = clip(a.fact or '', 120).replace /\.+$/, ''
      slug = if a.slug then " (#{a.slug})" else ''
      if fact
        "I want to remember this: #{fact}#{slug}."
      else
        "I want to save a memory#{slug}."
    when 'brain_put_entity', 'brain_put'
      slug = a.slug or 'an entity'
      detail = entityDetail a.content or a.body or ''
      if detail
        "I want to write brain record #{slug}: #{detail}."
      else
        "I want to write brain record #{slug}."
    when 'brain_delete_entity'
      "I want to permanently delete brain record #{a.slug or 'unknown'}."
    when 'todo_upsert'
      title = a.title or a.summary or ''
      if title
        "I want to create or update a task: #{clip title, 80}."
      else if a.id
        "I want to update task #{a.id}."
      else
        'I want to create or update a task.'
    when 'todo_take'
      "I want to take task #{a.id or 'unknown'}."
    when 'todo_release'
      "I want to release task #{a.id or 'unknown'}."
    when 'control_browser'
      "I want to control the browser: #{clip a.task or 'a browser task', 100}."
    when 'run_application'
      "I want to launch application #{a.app or 'unknown'}."
    when 'run_activity_command'
      "I want to run activity command #{a.id or 'unknown'}."
    else
      keys = Object.keys(a).sort()
      bits = for k in keys.slice(0, 3)
        "#{k}=#{clip String(a[k] ? ''), 40}"
      if bits.length
        "I want to run #{toolName} with #{bits.join ', '}."
      else
        "I want to run tool #{toolName}."

entityDetail = (content) ->
  t = String(content or '')
  return '' unless t.trim()
  m = t.match /(?:^|\n)\s*name:\s*["']?([^\n"']+)/i
  if m?[1]
    return clip m[1].trim(), 60
  m = t.match /(?:^|\n)\s*body:\s*["']?([^\n"']+)/i
  if m?[1] and m[1].trim() isnt '|'
    return clip m[1].trim(), 80
  m = t.match /\bbody:\s*\n\s*body:\s*["']?([^\n"']+)/i
  if m?[1]
    return clip m[1].trim(), 80
  clip t.replace(/\s+/g, ' ').trim(), 80

clip = (s, n = 80) ->
  t = String(s or '').replace(/\s+/g, ' ').trim()
  if t.length <= n then t else t.slice(0, n - 1) + '…'
