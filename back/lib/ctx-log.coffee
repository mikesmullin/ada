# Persistent context-window log (PLAN2 W7 + gl1 Lucy/Rosa style).
#
#   logs/ada.yaml           — current `messages:` = conversation context (rewritten)
#   logs/ada.archive.yaml   — messages rotated out by compaction (append-only)
#
# Unlike gl1, we do **not** truncate on process start. Restart reloads ada.yaml
# so Ada still knows the last things said. Compaction logrotates into archive.
#
# Diary (M7) input: always archive ∪ current window for the period
# (see collectDiaryCorpus). Map-reduce must not read only one of the two files.
import { existsSync, mkdirSync, readFileSync, writeFileSync, appendFileSync } from 'fs'
import { dirname, join } from 'path'
import yaml from 'js-yaml'

HEADER = '''# ada context window — persists across ada-back restarts
# messages: conversation turns used for prompt context (mirrors in-memory history)
# rotated (compacted) turns: logs/ada.archive.yaml
# Not truncated on process start — compaction logrotates instead.

'''

ARCHIVE_HEADER = '''# ada compacted context archive — append-only
# Messages rotated out of logs/ada.yaml by history compaction / ring trim.

'''

whoToRole = (who) ->
  switch String(who or '')
    when 'ada', 'assistant' then 'assistant'
    when 'system' then 'system'
    else 'user'

roleToWho = (role) ->
  switch String(role or '')
    when 'assistant' then 'ada'
    when 'system' then 'system'
    else 'user'

export defaultPath = (adaRoot) -> join adaRoot, 'logs', 'ada.yaml'

export archivePath = (msgPath) ->
  # logs/ada.yaml → logs/ada.archive.yaml
  if msgPath.endsWith '.yaml'
    msgPath.replace /\.yaml$/, '.archive.yaml'
  else
    "#{msgPath}.archive"

# Load messages from a single YAML log → [{ who, text, ts?, role, source? }, ...]
# opts.includeSystem: keep system role (default false — SOUL is separate for Ada).
export loadMessagesFile = (filePath, opts = {}) ->
  return [] unless filePath and existsSync filePath
  try
    raw = readFileSync filePath, 'utf8'
    doc = yaml.load(raw) or {}
    msgs = doc.messages or []
    out = []
    for m in msgs when m and (m.content? or m.text?)
      role = m.role or 'user'
      continue if role is 'system' and not opts.includeSystem
      text = String(m.content ? m.text ? '').replace(/\s+$/g, '')
      continue unless text
      entry =
        who: roleToWho role
        role: role
        text: text
      entry.ts = if m.ts then String(m.ts) else null
      out.push entry
    out
  catch e
    console.error "ctx-log: failed to load #{filePath}: #{e.message}"
    []

# Load messages from disk → [{ who, text, ts? }, ...] (current window only).
export loadHistory = (msgPath) ->
  loadMessagesFile msgPath, includeSystem: false

# Parse ISO / Date / ms → epoch ms, or null if unparseable.
parseTsMs = (ts) ->
  return null unless ts?
  if typeof ts is 'number' and Number.isFinite(ts)
    return if ts < 1e12 then ts * 1000 else ts
  t = Date.parse String(ts)
  if Number.isNaN(t) then null else t

# Stable key for de-dupe if a turn somehow appears in both files.
msgKey = (m) ->
  "#{m.ts or ''}|#{m.role or m.who or ''}|#{String(m.text or '').slice(0, 120)}"

# Diary / map-reduce corpus: **archive for the period ∪ current context window**.
#
# Order: archive (older rotated turns) first, then live `ada.yaml`.
# Filter: sinceMs < ts <= untilMs (since exclusive, until inclusive) when set.
# Messages without a parseable ts are kept when opts.keepUntimed is true (default
# true for current window only — they may still be relevant mid-session).
#
# Returns:
#   {
#     messages: [{ who, role, text, ts, source: 'archive'|'current' }, ...]
#     paths: { current, archive }
#     since, until
#     counts: { archive, current, total }
#   }
export collectDiaryCorpus = (opts = {}) ->
  msgPath = opts.msgPath or opts.ctxLogPath
  unless msgPath
    throw new Error 'collectDiaryCorpus: msgPath / ctxLogPath required'
  ap = opts.archivePath or archivePath msgPath
  sinceMs = parseTsMs opts.since
  untilMs = parseTsMs opts.until
  keepUntimed = if opts.keepUntimed is false then false else true

  inRange = (m, source) ->
    ms = parseTsMs m.ts
    unless ms?
      # Untimed: include from current window by default; skip untimed archive noise.
      return keepUntimed and source is 'current'
    return false if sinceMs? and ms <= sinceMs
    return false if untilMs? and ms > untilMs
    true

  archived = loadMessagesFile(ap, includeSystem: false).map (m) ->
    Object.assign {}, m, source: 'archive'
  current = loadMessagesFile(msgPath, includeSystem: false).map (m) ->
    Object.assign {}, m, source: 'current'

  archived = archived.filter (m) -> inRange m, 'archive'
  current = current.filter (m) -> inRange m, 'current'

  # Prefer archive order then current; drop exact dupes (same ts/role/prefix).
  seen = new Set()
  merged = []
  for m in archived.concat(current)
    k = msgKey m
    continue if seen.has k
    seen.add k
    merged.push m

  # Chronological when timestamps exist; untimed current msgs stay at end of their group.
  merged.sort (a, b) ->
    am = parseTsMs(a.ts) ? Number.MAX_SAFE_INTEGER
    bm = parseTsMs(b.ts) ? Number.MAX_SAFE_INTEGER
    if am isnt bm then am - bm else 0

  {
    messages: merged
    paths: { current: msgPath, archive: ap }
    since: opts.since ? null
    until: opts.until ? null
    counts:
      archive: archived.length
      current: current.length
      total: merged.length
  }

# Render corpus as plain text chunks for map-reduce microagents.
export formatCorpusForMap = (messages, opts = {}) ->
  maxChars = opts.maxChars or 12000
  chunks = []
  buf = ''
  flush = ->
    return unless buf
    chunks.push buf
    buf = ''
  for m in messages or []
    line = "[#{m.ts or '?'}] #{m.who or m.role}: #{m.text}\n"
    if buf.length + line.length > maxChars and buf
      flush()
    buf += line
  flush()
  chunks

# Rewrite the context-window file from the full in-memory history.
export rewriteMessages = (msgPath, history) ->
  return unless msgPath
  try
    mkdirSync dirname(msgPath), recursive: true
    messages = for h in (history or [])
      ts = h.ts or new Date().toISOString()
      {
        ts: ts
        role: whoToRole h.who
        content: String(h.text or '')
      }
    body = HEADER + yaml.dump({ messages }, {
      lineWidth: 100
      noRefs: true
      sorting: false
      # keep block scalars readable for multi-line replies
    })
    # Prefer literal block style for content when multi-line — js-yaml dump uses |
    # automatically for multi-line strings in many versions; fine if quoted.
    writeFileSync msgPath, body, 'utf8'
  catch e
    console.error "ctx-log: rewrite failed #{msgPath}: #{e.message}"

# Append compacted-out turns to the archive (logrotate side of compaction).
export appendArchive = (msgPath, dropped) ->
  return unless msgPath and dropped?.length
  try
    ap = archivePath msgPath
    mkdirSync dirname(ap), recursive: true
    unless existsSync ap
      writeFileSync ap, ARCHIVE_HEADER + 'messages:\n', 'utf8'
    chunk = ''
    for h in dropped
      ts = h.ts or new Date().toISOString()
      role = whoToRole h.who
      text = String(h.text or '')
      # Manual YAML fragment so we can append without re-parsing the whole archive.
      escaped = text.replace /\n/g, '\n      '
      chunk += "  - ts: #{JSON.stringify ts}\n"
      chunk += "    role: #{role}\n"
      chunk += "    content: |\n      #{escaped}\n"
      chunk += '\n'
    appendFileSync ap, chunk, 'utf8'
  catch e
    console.error "ctx-log: archive append failed: #{e.message}"

# Drop oldest entries from history to maxLen; archive them; rewrite main log.
# Returns { history, dropped }.
export compactAndPersist = (msgPath, history, maxLen) ->
  hist = history or []
  maxLen = Math.max 2, maxLen or 64
  dropped = []
  while hist.length > maxLen
    dropped.push hist.shift()
  if dropped.length
    appendArchive msgPath, dropped
  rewriteMessages msgPath, hist
  { history: hist, dropped }

# Stamp missing timestamps on new turns (ISO).
export stampNow = -> new Date().toISOString()
