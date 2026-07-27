# Random 3-word spoken approval phrases (PLAN2 Tom).
# In-repo dictionaries only — no npm/docker dependency.
# Pattern inspired by Docker namesgenerator / petname (adjective + noun-ish).
import { readFileSync, readdirSync } from 'fs'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'
import { randomInt } from 'crypto'

DICT_DIR = join dirname(fileURLToPath(import.meta.url)), 'dicts'

loadWords = (name) ->
  path = join DICT_DIR, name
  text = readFileSync path, 'utf8'
  text.split(/\r?\n/).map((w) -> w.trim().toLowerCase()).filter (w) ->
    w and not w.startsWith('#') and /^[a-z]+$/.test(w)

# Prefer diverse buckets when present
BUCKETS = ['adjectives.txt', 'animals.txt', 'colors.txt', 'nouns.txt', 'surnames.txt']

lists = null
ensureLists = ->
  return lists if lists
  lists = []
  for f in BUCKETS
    try
      words = loadWords f
      lists.push words if words.length
    catch e then null
  if lists.length < 2
    # fallback minimal if dicts missing
    lists = [
      ['calm', 'bright', 'swift', 'noble', 'quiet']
      ['otter', 'falcon', 'river', 'beacon', 'comet']
      ['bailey', 'carter', 'reed', 'stone', 'wells']
    ]
  lists

pick = (arr) -> arr[randomInt arr.length]

# Exactly three words, space-joined, lowercase, speech-friendly.
export randomApprovePhrase = ->
  ensureLists()
  # Use up to 3 different lists for variety; reuse if fewer than 3 files.
  a = lists[0]
  b = lists[1 % lists.length]
  c = lists[2 % lists.length]
  # Prefer three distinct source lists when we have 3+
  if lists.length >= 3
    b = lists[1]
    c = lists[2]
  "#{pick a} #{pick b} #{pick c}"

export normalizeSpeech = (text) ->
  String(text or '')
    .toLowerCase()
    .replace(/[^a-z\s]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()

# True if spoken text contains the three words in order (allow extra fluff).
export matchesApprovePhrase = (spoken, phrase) ->
  s = normalizeSpeech spoken
  parts = normalizeSpeech(phrase).split ' '
  return false unless parts.length is 3
  # exact three-word utterance
  return true if s is parts.join ' '
  # allow surrounding words: ... calm otter bailey ...
  rx = new RegExp("\\b#{parts[0]}\\s+#{parts[1]}\\s+#{parts[2]}\\b")
  rx.test s

export matchesDenyPhrase = (spoken, denyPhrases) ->
  s = normalizeSpeech spoken
  for p in denyPhrases or []
    d = normalizeSpeech p
    return true if d and (s is d or s.includes d)
  false
