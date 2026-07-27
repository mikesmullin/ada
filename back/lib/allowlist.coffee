# Deny-by-default tool allowlist (gl1 Lucy/Rosa pattern, CoffeeScript port).
# One rule per line: `tool` or `tool:params`. Case-insensitive.
# `*` is match-anything. Full-match patterns. Comments (#) and blanks ignored.
# Re-read the file on every check — caller passes fresh text each time.

export matchToken = (pattern, text) ->
  return true if pattern is '*'
  esc = String(pattern).replace /[.+?^${}()|[\]\\]/g, '\\$&'
  rx = new RegExp('^' + esc.replace(/\*/g, '.*') + '$', 'i')
  rx.test String(text ? '')

# True iff some line permits tool_name (+ optional params for terminal-like tools).
export isAllowed = (allowlistText, toolName, params = '') ->
  return false unless allowlistText? and String(allowlistText).trim()
  name = String(toolName or '')
  isTerminal = /^terminal/i.test(name)
  for rawLine in String(allowlistText).split /\r?\n/
    line = rawLine.trim()
    continue if not line or line.startsWith '#'
    colon = line.indexOf ':'
    if colon >= 0
      toolPat = line.slice(0, colon).trim()
      paramPat = line.slice(colon + 1).trim()
    else
      toolPat = line
      paramPat = null
    continue unless matchToken toolPat, name
    # Tool matched. Params: absent ⇒ allowed. Present ⇒ only enforced for
    # terminal tools (or when params string was provided).
    return true unless paramPat?
    return true if not isTerminal and not params
    return true if matchToken paramPat, params or ''
  false
