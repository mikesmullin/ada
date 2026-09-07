# Tool gate: allowlist (deny-by-default) + risk tiers (PLAN2 W3).
# Re-reads allowlist file on every tool call.
import { existsSync, readFileSync } from 'fs'
import { isAllowed } from './allowlist.coffee'

# Default risks when not listed in config.tool_risk.
# Mutations / browser = medium (Tom when confirm.enabled); pure reads = low.
DEFAULT_RISK =
  current_time: 'low'
  desk_light: 'low'
  pc_light_color: 'low'
  alarm__create: 'low'
  alarm__list: 'low'
  alarm__update: 'low'
  alarm__delete: 'low'
  alarm__show: 'low'
  alarm__snooze: 'low'
  timer__create: 'low'
  timer__dismiss: 'low'
  timer__show: 'low'
  media_control: 'low'
  run_application: 'medium'
  run_activity_command: 'medium'
  shutdown: 'high'
  # Host-browser control is direct agent_browser_* tools (no sub-agent).
  # Reads run free via the allowlist below; mutating calls go through Tom (ask mode).
  agent_browser_tools_profiles: 'low'
  agent_browser_tab_list: 'low'
  agent_browser_snapshot: 'low'
  agent_browser_get_text: 'low'
  agent_browser_get_url: 'low'
  agent_browser_get_title: 'low'
  agent_browser_get_value: 'low'
  agent_browser_get_attr: 'low'
  agent_browser_is_visible: 'low'
  agent_browser_is_enabled: 'low'
  agent_browser_is_checked: 'low'
  agent_browser_screenshot: 'low'
  agent_browser_dialog_status: 'low'
  agent_browser_console: 'low'
  agent_browser_read: 'low'
  agent_browser_webmcp_list: 'low'
  agent_browser_wait_ms: 'low'
  agent_browser_wait_for_selector: 'low'
  agent_browser_wait_for_text: 'low'
  agent_browser_wait_for_url: 'low'
  agent_browser_wait_for_load: 'low'
  agent_browser_open: 'medium'
  agent_browser_tab_new: 'medium'
  agent_browser_tab_close: 'medium'
  agent_browser_tab_switch: 'medium'
  agent_browser_window_new: 'medium'
  agent_browser_close: 'medium'
  agent_browser_back: 'medium'
  agent_browser_forward: 'medium'
  agent_browser_reload: 'medium'
  agent_browser_click: 'medium'
  agent_browser_dblclick: 'medium'
  agent_browser_drag: 'medium'
  agent_browser_fill: 'medium'
  agent_browser_type: 'medium'
  agent_browser_press: 'medium'
  agent_browser_check: 'medium'
  agent_browser_uncheck: 'medium'
  agent_browser_select: 'medium'
  agent_browser_scroll: 'medium'
  agent_browser_scroll_into_view: 'medium'
  agent_browser_hover: 'medium'
  agent_browser_focus: 'medium'
  agent_browser_find: 'medium'
  agent_browser_frame_switch: 'medium'
  agent_browser_frame_main: 'medium'
  agent_browser_eval: 'medium'
  agent_browser_dialog_accept: 'medium'
  agent_browser_dialog_dismiss: 'medium'
  agent_browser_tap: 'medium'
  agent_browser_swipe: 'medium'
  agent_browser_upload: 'medium'
  agent_browser_webmcp_invoke: 'medium'
  agent_browser_webmcp_result: 'medium'
  agent_browser_webmcp_cancel: 'medium'
  work_power: 'medium'
  work_unlock: 'medium'
  work_login: 'medium'
  work_duo: 'medium'
  work_kvm: 'medium'
  work_kvm_close: 'medium'
  remember_fact: 'medium'
  recall_search: 'low'
  brain_search: 'low'
  brain_think: 'low'
  brain_ontology: 'low'
  brain_graph: 'low'
  brain_graphql: 'low'
  brain_get_entity: 'low'
  brain_put_entity: 'medium'
  brain_delete_entity: 'medium'
  brain_schema_methods: 'low'
  brain_method_invoke: 'medium'
  brain_schema_orphans: 'low'
  todo_lists: 'low'
  todo_next: 'low'
  todo_tree: 'low'
  todo_view: 'low'
  todo_take: 'medium'
  todo_release: 'medium'
  todo_upsert: 'medium'
  # Local filesystem (mcp-file-io): reads run free via the allowlist;
  # writes go through Tom (ask mode).
  list_dir: 'low'
  read_file: 'low'
  grep: 'low'
  find: 'low'
  stat: 'low'
  write_file: 'medium'
  edit: 'medium'

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
