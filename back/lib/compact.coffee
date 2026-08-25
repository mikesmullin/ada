# Line-at-a-time front-trim of Angela/agl context_window when near n_ctx.

estimateTokens = (s) -> Math.ceil(String(s or '').length / 4)

contentTokens = (m) ->
  n = estimateTokens m.content
  if Array.isArray m.tool_calls
    n += estimateTokens JSON.stringify(m.tool_calls)
  n

# Hide/trim oldest visible lines until estimated prompt tokens fit budget.
# Mutates agent.context_window in place. Returns number of lines dropped.
export compactContextWindow = (agent, opts = {}) ->
  return 0 unless agent and Array.isArray agent.context_window
  size = Number agent.context_window_size or opts.maxTokens or 0
  return 0 unless size > 0
  reserve = Number opts.reserveTokens or 8000
  budget = Math.max 1000, size - reserve
  used = Number agent.last_prompt_tokens
  unless Number.isFinite(used) and used > 0
    used = 0
    used += estimateTokens agent.system_prompt
    for m in agent.context_window when m and m.visible isnt false
      used += contentTokens m
  return 0 if used <= budget

  dropped = 0
  while used > budget
    target = null
    for m in agent.context_window
      continue unless m and m.visible isnt false
      text = String m.content ? ''
      continue unless text.trim()
      target = m
      break
    break unless target
    lines = String(target.content ? '').split '\n'
    # drop first non-empty line (and any following blank)
    cut = 0
    while cut < lines.length and not String(lines[cut]).trim()
      cut++
    cut++
    removed = lines.slice(0, cut).join '\n'
    rest = lines.slice(cut).join '\n'
    used -= estimateTokens removed
    dropped++
    if rest.trim()
      target.content = rest
    else
      target.content = ''
      target.visible = false
  dropped
