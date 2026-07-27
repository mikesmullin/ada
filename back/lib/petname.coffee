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

# American Soundex (US census algorithm) — Whisper often returns a same-sound
# spelling (lime/line, deer/dear, raven/ravin). Codes are letter + 3 digits.
export soundex = (word) ->
  w = String(word or '').toLowerCase().replace /[^a-z]/g, ''
  return '' unless w.length
  # Map consonants to digits; vowels / h / w / y are skipped (after first letter).
  map =
    b: '1', f: '1', p: '1', v: '1'
    c: '2', g: '2', j: '2', k: '2', q: '2', s: '2', x: '2', z: '2'
    d: '3', t: '3'
    l: '4'
    m: '5', n: '5'
    r: '6'
  first = w[0]
  code = first.toUpperCase()
  prev = map[first] or '0'
  i = 1
  while i < w.length and code.length < 4
    ch = w[i]
    d = map[ch]
    if d
      # Skip adjacent same codes (and those separated only by h/w).
      if d isnt prev
        code += d
        prev = d
    else if ch not in ['h', 'w']
      # Vowel / y breaks adjacent-same rule
      prev = '0'
    i++
  (code + '000').slice 0, 4

# True if two words are the same spelling or same Soundex code.
wordsSoundAlike = (a, b) ->
  aa = String(a or '').toLowerCase()
  bb = String(b or '').toLowerCase()
  return true if aa is bb
  sa = soundex aa
  sb = soundex bb
  sa.length is 4 and sa is sb

# True if spoken text contains the three challenge words **in order**, each
# matching by exact spelling or Soundex (extra words before/between/after OK).
export matchesApprovePhrase = (spoken, phrase) ->
  spokenWords = normalizeSpeech(spoken).split(' ').filter (w) -> w.length
  want = normalizeSpeech(phrase).split(' ').filter (w) -> w.length
  return false unless want.length is 3
  return false unless spokenWords.length >= 3

  # Greedy scan: find word0, then word1 after it, then word2 after that.
  wi = 0
  for sw in spokenWords
    if wordsSoundAlike sw, want[wi]
      wi += 1
      return true if wi is 3
  false

export matchesDenyPhrase = (spoken, denyPhrases) ->
  s = normalizeSpeech spoken
  for p in denyPhrases or []
    d = normalizeSpeech p
    return true if d and (s is d or s.includes d)
    # Soundex deny for the multi-word phrase as ordered sound-alike sequence.
    if d and matchesApprovePhrase(spoken, d)
      return true
  false
