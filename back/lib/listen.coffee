# Active-listen waiter: VAD-gated start timeout + silence debounce + pause-newlines.
# Mic energy from perception-voice FeatureFrames (same stream the avatar shaders use).
import net from 'node:net'

FRAME_SIZE = 36
MAGIC = 0x31465641
FLAG_VAD = 1
RMS_FLOOR = 0.02
PAUSE_NL_MS = 1000
export SILENCE_MS = 3000
export DEFAULT_START_MS = 6000

# Binary FeatureFrame after subscribe-levels JSON ack (docs/PROTOCOL.md §1).
export parseFeatureFrame = (buf, offset = 0) ->
  return null if buf.length < offset + FRAME_SIZE
  magic = buf.readUInt32LE offset
  return null unless magic is MAGIC
  {
    rms: buf.readFloatLE offset + 8
    flags: buf.readUInt32LE offset + 32
    speaking: false
  }

speakingFromFrame = (f) ->
  return false unless f
  Boolean(f.flags & FLAG_VAD) or (Number(f.rms) or 0) > RMS_FLOOR

frameJson = (obj) ->
  payload = Buffer.from JSON.stringify(obj), 'utf8'
  header = Buffer.alloc 4
  header.writeUInt32BE payload.length
  Buffer.concat [header, payload]

# Subscribe to perception-voice levels. Calls onFrame({rms, flags, speaking}).
export connectLevels = (sockPath, onFrame, log = ->) ->
  acc = Buffer.alloc 0
  jsonMode = true
  subscribed = false
  sock = net.connect sockPath, ->
    sock.write frameJson command: 'subscribe', channel: 'levels'
  sock.on 'data', (d) ->
    acc = Buffer.concat [acc, d]
    if jsonMode
      return if acc.length < 4
      len = acc.readUInt32BE 0
      return if acc.length < 4 + len
      payload = acc.subarray 4, 4 + len
      acc = acc.subarray 4 + len
      try
        msg = JSON.parse payload.toString 'utf8'
      catch e
        log "levels ack parse failed: #{e.message}"
        sock.end()
        return
      if msg.status is 'ok' or msg.status is 'OK'
        jsonMode = false
        subscribed = true
        log 'subscribed to perception-voice levels stream'
      else
        log "levels subscribe rejected: #{JSON.stringify msg}"
        sock.end()
        return
    # binary frames; resync on magic
    loop
      if acc.length < FRAME_SIZE
        break
      if acc.readUInt32LE(0) isnt MAGIC
        idx = acc.indexOf Buffer.from [0x41, 0x56, 0x46, 0x31] # 'AVF1' LE
        if idx < 0
          acc = acc.subarray acc.length - 3
          break
        acc = acc.subarray idx
        continue if acc.length < FRAME_SIZE
      f = parseFeatureFrame acc, 0
      acc = acc.subarray FRAME_SIZE
      continue unless f
      f.speaking = speakingFromFrame f
      try onFrame f
      catch e then log "levels onFrame: #{e.message}"
  sock.on 'error', (e) -> log "levels stream error: #{e.message}"
  sock.on 'close', ->
    log 'levels stream lost; reconnecting…' if subscribed
    setTimeout (-> connectLevels sockPath, onFrame, log), 1000
  sock

# Mutable listen/gather buffer with pause-newlines.
export createTranscriptBuf = ->
  text: ''
  lastWordAt: Date.now()
  lastPartial: ''

export feedPartial = (buf, partial, speaking) ->
  t = String(partial or '').trim()
  now = Date.now()
  if t and t isnt buf.lastPartial
    # grow committed prefix when the partial extends
    if t.startsWith buf.lastPartial
      extra = t.slice buf.lastPartial.length
      buf.text += extra
    else if not buf.text or t.length >= buf.lastPartial.length
      # replacement hypothesis — keep pause-newlines already in buf.text if any
      nl = (buf.text.match(/\n+$/) or [''])[0]
      buf.text = t + nl
    buf.lastPartial = t
    buf.lastWordAt = now
  else if not speaking and buf.text and (now - buf.lastWordAt) >= PAUSE_NL_MS
    unless buf.text.endsWith '\n'
      buf.text += '\n'
      buf.lastWordAt = now
  buf

export feedUtterance = (buf, text) ->
  t = String(text or '').trim()
  return buf unless t
  # Prefer the finalized utterance over partials, keep trailing pause newlines.
  nl = (buf.text.match(/\n+$/) or [''])[0]
  # If we already accumulated pause-split lines, append this as the last line
  # when the utterance contains the last partial; else replace.
  if buf.text and buf.lastPartial and t.toLowerCase().includes(buf.lastPartial.trim().toLowerCase().slice(0, 40))
    # rebuild from finalized but restore extra newlines we inserted
    linesHint = buf.text.split('\n').length
    buf.text = t + nl
    if linesHint > 1 and not t.includes('\n')
      # keep at least the trailing pause break
      buf.text = t + nl
  else if buf.text and buf.text.replace(/\n/g, ' ').trim() and t
    unless buf.text.endsWith '\n'
      buf.text += '\n'
    buf.text += t
  else
    buf.text = t + nl
  buf.lastPartial = t
  buf.lastWordAt = Date.now()
  buf

export snapshotText = (buf) ->
  String(buf?.text or '').replace(/\n+$/g, '').trim()

# One in-flight listen session.
# The ear opens immediately. Start-timeout only after releaseStartClock()
# (Ada finished vocalizing). Finish-timeout is armed only when the STT
# buffer grows — VAD/gain does not open it. Once armed, live mic energy
# holds the silence debounce so Whisper lag cannot end the turn mid-speech.
export createListenSession = ({ timeoutSec, onStart, onEnd, onTick, log } = {}) ->
  startMs = Math.max 500, Math.round((Number(timeoutSec) or DEFAULT_START_MS / 1000) * 1000) or DEFAULT_START_MS
  session =
    startedAt: Date.now()
    startClockAt: null
    heardWords: false
    lastWordAt: 0
    startMs: startMs
    silenceMs: SILENCE_MS
    buf: createTranscriptBuf()
    done: false
    held: false
    heldSince: null
    resolve: null
    reject: null
    timer: null
  session.promise = new Promise (resolve, reject) ->
    session.resolve = resolve
    session.reject = reject

  session.hud = ->
    now = Date.now()
    # PTT hold: no fuse. Clocks pause until LMB up.
    if session.held
      { phase: 1, remain: 1, total: 0 }
    else if session.heardWords
      remain = Math.max 0, SILENCE_MS - (now - (session.lastWordAt or now))
      { phase: 4, remain, total: SILENCE_MS }
    else if session.startClockAt?
      remain = Math.max 0, startMs - (now - session.startClockAt)
      { phase: 2, remain, total: startMs }
    else
      { phase: 1, remain: 1, total: 0 }

  finish = (result) ->
    return if session.done
    session.done = true
    clearInterval session.timer if session.timer?
    session.timer = null
    try onEnd? session, result
    catch e then log? "listen onEnd: #{e.message}"
    session.resolve result

  emitTick = ->
    return if session.done
    try onTick? session
    catch e then log? "listen onTick: #{e.message}"

  noteWords = ->
    t = snapshotText session.buf
    return unless t
    unless session.heardWords
      session.heardWords = true
      log? 'ear: STT gate — finish timeout armed'
    session.lastWordAt = Date.now()

  session.releaseStartClock = ->
    return if session.done or session.heardWords or session.startClockAt?
    session.startClockAt = Date.now()
    log? 'ear: start timeout began'
    emitTick()

  # After she goes quiet: if the buffer already has words, arm finish
  # instead of the start clock (barge-in in progress).
  session.armFromBufferIfAny = ->
    return if session.done
    noteWords() if snapshotText session.buf

  session.advance = (now) ->
    return if session.done
    if session.held
      emitTick()
      return
    if not session.heardWords and session.startClockAt? and
        (now - session.startClockAt) >= startMs
      finish { ok: false, reason: 'timeout', text: '' }
      return
    if session.heardWords and session.lastWordAt and
        (now - session.lastWordAt) >= SILENCE_MS
      text = snapshotText session.buf
      if text
        finish { ok: true, reason: 'ok', text }
      else
        finish { ok: false, reason: 'timeout', text: '' }
      return
    emitTick()

  # Pause start/finish clocks for the duration of a PTT hold so LMB, not
  # VAD or listen timeouts, is end-of-utterance. Hold time is added back
  # onto the clocks so it does not eat the budget.
  session.setHeld = (held) ->
    return if session.done
    now = Date.now()
    next = Boolean held
    if next and not session.held
      session.held = true
      session.heldSince = now
      log? 'ear: PTT hold — clocks paused'
    else if not next and session.held
      dt = now - (session.heldSince or now)
      session.held = false
      session.heldSince = null
      session.startClockAt += dt if session.startClockAt?
      session.lastWordAt += dt if session.lastWordAt
      log? 'ear: PTT release — clocks resumed'
    emitTick()

  # LMB-up end-of-utterance: finish now if we have text. Empty hold is a
  # no-op (start-timeout keeps running).
  session.commit = ->
    return if session.done
    text = snapshotText session.buf
    return unless text
    noteWords()
    finish { ok: true, reason: 'ok', text }

  session.tickLevels = (frame) ->
    now = Date.now()
    if not session.held and session.heardWords and
        (frame?.speaking or speakingFromFrame(frame))
      session.lastWordAt = now
    session.advance now

  session.feedPartial = (text, speaking) ->
    return if session.done
    before = snapshotText session.buf
    feedPartial session.buf, text, speaking
    after = snapshotText session.buf
    # During her vocalization (no start clock yet), ignore partials as the
    # finish gate so TTS leaking into STT cannot start the silence clock.
    # Finalized utterances still gate via feedUtterance.
    if after and after isnt before and (session.startClockAt? or session.heardWords)
      noteWords()
    emitTick()

  session.feedUtterance = (text) ->
    return if session.done
    feedUtterance session.buf, text
    noteWords() if snapshotText session.buf
    emitTick()

  session.cancel = (reason = 'click') ->
    finish { ok: false, reason, text: snapshotText session.buf }

  try onStart? session
  catch e then log? "listen onStart: #{e.message}"
  emitTick()
  session.timer = setInterval (-> session.advance Date.now()), 50
  session
