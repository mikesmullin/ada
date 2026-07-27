# Tom the Security Guy — confirmation microagent boundary (PLAN2 M4).
# One decision: approve or deny a gated tool call via spoken 3-word phrase.
# Voice: presence-voice preset `norman`. STT: next utterance(s) from perception.
import { randomApprovePhrase, matchesApprovePhrase, matchesDenyPhrase, normalizeSpeech } from './petname.coffee'

# Active wait: set by waitForSpokenConfirm; consumed by feedUtterance.
waiter = null

export isWaiting = -> waiter?

# Called from ada-back words stream when Tom is listening.
export feedUtterance = (text) ->
  return false unless waiter
  w = waiter
  if matchesDenyPhrase text, w.denyPhrases
    finish w, { approved: false, reason: 'denied', spoken: text }
    return true
  if matchesApprovePhrase text, w.phrase
    finish w, { approved: true, reason: 'approved', spoken: text }
    return true
  # ignore unrelated speech; keep waiting until timeout
  w.onIgnored?(text)
  true

finish = (w, result) ->
  return unless waiter is w
  clearTimeout w.timer if w.timer
  waiter = null
  w.resolve result

# Wait for approve/deny/timeout. Does not speak — caller speaks challenge first.
export waitForSpokenConfirm = ({ phrase, denyPhrases, timeoutMs, onIgnored }) ->
  if waiter
    # Nested confirm should not happen; fail closed
    return { approved: false, reason: 'busy' }
  new Promise (resolve) ->
    w = { phrase, denyPhrases, resolve, onIgnored, timer: null }
    waiter = w
    w.timer = setTimeout ->
      finish w, { approved: false, reason: 'timeout' }
    , timeoutMs or 60000

# Full Tom flow: speak challenge with norman, wait for STT, return result.
export tomConfirm = ({
  toolName
  args
  risk
  speakOnce
  voiceTom
  denyPhrases
  timeoutMs
  log
}) ->
  phrase = randomApprovePhrase()
  summary = summarizeTool toolName, args
  challenge = "Tom here, security. #{summary} " +
    "To approve, say exactly: #{phrase}. " +
    "To deny, say: #{denyPhrases?[0] or 'belay that order'}."

  log? "tom challenge [#{risk}] #{toolName}: approve=\"#{phrase}\""
  try
    await speakOnce voiceTom or 'norman', challenge, 'interrupt'
  catch e
    log? "tom speak failed: #{e.message}"
    return { approved: false, reason: 'speak_failed', phrase, error: e.message }

  result = await waitForSpokenConfirm
    phrase: phrase
    denyPhrases: denyPhrases or ['belay that order']
    timeoutMs: timeoutMs or 60000
    onIgnored: (text) ->
      log? "tom ignored utterance: #{normalizeSpeech text}"

  log? "tom result: #{result.reason} approved=#{result.approved}"
  result.phrase = phrase
  result

summarizeTool = (toolName, args) ->
  a = args or {}
  switch toolName
    when 'remember_fact'
      "I want to save a memory: #{clip a.fact or a.slug or 'a fact'}."
    when 'brain_put_entity'
      "I want to write brain entity #{a.slug or 'unknown'}."
    when 'todo_upsert'
      "I want to create or update a task#{if a.title then ": #{clip a.title}" else ''}."
    when 'todo_take'
      "I want to take task #{a.id or ''}."
    when 'todo_release'
      "I want to release task #{a.id or ''}."
    when 'control_browser'
      "I want to control the browser: #{clip a.task or 'a browser task'}."
    when 'run_application'
      "I want to launch application #{a.app or 'unknown'}."
    when 'run_activity_command'
      "I want to run activity command #{a.id or 'unknown'}."
    else
      "I want to run tool #{toolName}."

clip = (s, n = 80) ->
  t = String(s or '').replace(/\s+/g, ' ').trim()
  if t.length <= n then t else t.slice(0, n - 1) + '…'
