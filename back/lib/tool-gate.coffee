# Tool gate: allowlist (deny-by-default) + risk tiers (PLAN2 W3).
# Re-reads allowlist file on every tool call.
import { existsSync, readFileSync } from 'fs'
import { isAllowed } from './allowlist.coffee'

# Default risks when not listed in config.tool_risk.
# Mutations / browser = medium (Tom when confirm.enabled); pure reads = low.
DEFAULT_RISK =
  current_time: 'low'
  mock_slow_tool: 'low' # temporary M5 test tool — remove when done
  desk_light: 'low'
  pc_light_color: 'low'
  media_control: 'low'
  run_application: 'medium'
  run_activity_command: 'medium'
  control_browser: 'medium'
  remember_fact: 'medium'
  recall_search: 'low'
  brain_search: 'low'
  brain_think: 'low'
  brain_ontology: 'low'
  brain_graph: 'low'
  brain_graphql: 'low'
  brain_get_entity: 'low'
  brain_put_entity: 'medium'
  brain_schema_methods: 'low'
  brain_method_invoke: 'medium'
  todo_lists: 'low'
  todo_next: 'low'
  todo_tree: 'low'
  todo_view: 'low'
  todo_take: 'medium'
  todo_release: 'medium'
  todo_upsert: 'medium'

export riskOf = (toolName, configRisk = {}) ->
  r = configRisk[toolName] ? DEFAULT_RISK[toolName] ? 'medium'
  if r in ['low', 'medium', 'high'] then r else 'medium'

export readAllowlist = (path) ->
  return '' unless path and existsSync path
  try
    readFileSync path, 'utf8'
  catch e
    ''

# Serialize args for param patterns (e.g. run_activity_command:id).
export argsParamString = (toolName, args) ->
  return '' unless args and typeof args is 'object'
  if toolName is 'run_activity_command' and args.id?
    return String args.id
  if toolName is 'run_application' and args.app?
    return String args.app
  # Compact stable key=value list for optional future patterns
  keys = Object.keys(args).sort()
  return '' unless keys.length
  keys.map((k) -> "#{k}=#{args[k]}").join ' '

export checkToolGate = ({ toolName, args, allowlistPath, configRisk, confirmEnabled }) ->
  text = readAllowlist allowlistPath
  params = argsParamString toolName, args
  allowed = isAllowed text, toolName, params
  risk = riskOf toolName, configRisk

  # PLAN2: not allowlisted → Tom when enabled, else hard deny.
  # allowlisted low → run. allowlisted medium/high → Tom when enabled.
  if not allowed
    if confirmEnabled
      return {
        ok: false
        needsTom: true
        risk
        message: "blocked: tool #{toolName} was denied (not allowlisted; Tom denied or timed out)."
      }
    return {
      ok: false
      needsTom: false
      risk
      message: "blocked: tool #{toolName} is not on the allowlist " +
        "(deny-by-default; risk=#{risk})."
    }

  if confirmEnabled and risk in ['medium', 'high']
    return {
      ok: false
      needsTom: true
      risk
      message: "blocked: tool #{toolName} was denied by Tom (risk=#{risk})."
    }

  { ok: true, risk, needsTom: false }
