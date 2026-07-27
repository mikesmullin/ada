# Tom the Security Guy — confirmation microagent boundary (PLAN2 M4).
# One decision: approve or deny a gated tool call via spoken 3-word phrase.
# Voice: presence-voice preset `norman`. STT: next utterance(s) from perception.
# Stays in the confirm loop until approve / deny / silence timeout (not Ada).
import { randomApprovePhrase, matchesApprovePhrase, matchesDenyPhrase, normalizeSpeech } from './petname.coffee'

# Active wait: set by waitForSpokenConfirm; consumed by feedUtterance.
waiter = null

export isWaiting = -> waiter?

# Called from ada-back words stream when Tom is listening.
export feedUtterance = (text) ->
  return false unless waiter
  w = waiter
  # Any speech while Tom is waiting resets the silence timeout.
  w.resetTimer?()
  if matchesDenyPhrase text, w.denyPhrases
    finish w, { approved: false, reason: 'denied', spoken: text }
    return true
  if matchesApprovePhrase text, w.phrase
    finish w, { approved: true, reason: 'approved', spoken: text }
    return true
  # Wrong/unrelated speech: re-prompt in character (do not hand off to Ada).
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
    return { approved: false, reason: 'busy' }
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

# Full Tom flow: speak challenge with norman (+ captions), wait for STT.
# On ignored speech, re-speak the same challenge until approve/deny/timeout.
export tomConfirm = ({
  toolName
  args
  risk
  speakOnce
  broadcast
  voiceTom
  denyPhrases
  timeoutMs
  log
}) ->
  phrase = randomApprovePhrase()
  summary = summarizeTool toolName, args
  denyLine = denyPhrases?[0] or 'belay that order'
  challenge = "Tom here, security. #{summary} " +
    "To approve, say exactly: #{phrase}. " +
    "To deny, say: #{denyLine}."

  log? "tom challenge [#{risk}] #{toolName}: approve=\"#{phrase}\""

  repromptBusy = false
  lastReprompt = 0
  MIN_REPROMPT_MS = 2500

  speakChallenge = (schedule = 'interrupt') ->
    # Caption like Ada: who=tom so the avatar shows closed captions.
    try
      broadcast? { ev: 'caption', who: 'tom', text: challenge }
    catch e then null
    try
      await speakOnce voiceTom or 'norman', challenge, schedule
    catch e
      log? "tom speak failed: #{e.message}"
      throw e

  try
    await speakChallenge 'interrupt'
  catch e
    return { approved: false, reason: 'speak_failed', phrase, error: e.message }

  result = await waitForSpokenConfirm
    phrase: phrase
    denyPhrases: denyPhrases or ['belay that order']
    timeoutMs: timeoutMs or 60000
    onIgnored: (text) ->
      log? "tom ignored utterance: #{normalizeSpeech text} — re-prompting"
      now = Date.now()
      return if repromptBusy
      return if now - lastReprompt < MIN_REPROMPT_MS
      repromptBusy = true
      lastReprompt = now
      # Fire-and-forget re-speak; stay in confirm loop (do not resolve waiter).
      speakChallenge('interrupt')
        .catch (e) -> log? "tom re-prompt failed: #{e.message}"
        .finally -> repromptBusy = false

  # Clear Tom caption when leaving the gate (approve/deny/timeout).
  try
    broadcast? { ev: 'caption', who: 'tom', text: '' }
  catch e then null

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
