local Promise = require('opencode.promise')
local id = require('opencode.id')
local log = require('opencode.log')
local catalog = require('opencode.protocols.pi.catalog')
local process = require('opencode.protocols.pi.process')
local sessions = require('opencode.protocols.pi.sessions')

---Pi mirrors the v2 operation surface so shared callers need no protocol branches.
---@diagnostic disable-next-line: missing-fields
local M = {} --[[@as OpencodePiOperations]]

---@param session_id string
---@return OpencodePiSessionFact|nil
local function stored_session(session_id)
  return sessions.find(session_id)
end

---@param pi_state OpencodePiState
---@param location? OpencodeLocation
---@return table
local function live_session(pi_state, location)
  local now = vim.uv.now()
  return {
    id = pi_state.sessionId,
    title = '',
    location = location or { directory = vim.fn.getcwd() },
    time = { created = now, updated = now },
  }
end

---@param fact OpencodePiSessionFact
---@return table
local function public_session(fact)
  return { id = fact.id, title = fact.title, location = fact.location, time = fact.time }
end

---@param location? OpencodeLocation
---@return table[]
local function list_in(location)
  local result = {}
  for _, fact in ipairs(sessions.list()) do
    if not location or fact.location.directory == location.directory then
      result[#result + 1] = public_session(fact)
    end
  end
  return result
end

---@param connection OpencodePiConnection
---@return OpencodePiState
local function current_state(connection)
  local pi_state = process.get():get_state():await()
  connection.pi.session_id = pi_state.sessionId
  return pi_state
end

---Pi has one live session; operating on another requires switching the process to it.
---@param connection OpencodePiConnection
---@param session_id string
local function ensure_active(connection, session_id)
  if current_state(connection).sessionId == session_id then
    return
  end
  local fact = stored_session(session_id)
  if not fact then
    error('Pi session not found: ' .. session_id, 0)
  end
  local result = process.get():switch_session(fact.path):await()
  if result.cancelled then
    error('Pi refused to switch session', 0)
  end
  connection.pi.session_id = session_id
end

---A crashed pi is only restarted by operations that start new work, and says so; everything else fails.
---@return Promise<any>
local function revive()
  local handle = process.get().process
  if not handle.crashed then
    return Promise.new():resolve(nil)
  end
  log.warn('pi process had exited unexpectedly; restarting it')
  return handle:restart()
end

---Skips requests that would not change anything, so a plain prompt costs no extra round trips.
---@param provider? string
---@param model_id? string
---@param variant? string
local function apply_selection(provider, model_id, variant)
  local client = process.get()
  local pi_state = client:get_state():await()
  local changed = false
  local current = pi_state.model
  if provider and model_id and (not current or current.provider ~= provider or current.id ~= model_id) then
    client:set_model(provider, model_id):await()
    changed = true
  end
  if variant and (changed or variant ~= pi_state.thinkingLevel) then
    client:set_thinking_level(variant):await()
  end
end

function M.list_sessions(_, location)
  return Promise.new():resolve({ data = list_in(location), cursor = {} })
end

function M.list_sessions_project(_, location)
  return Promise.new():resolve(list_in(location))
end

function M.list_sessions_global()
  return Promise.new():resolve(list_in(nil))
end

M.get_session = Promise.async(function(connection, session_id)
  local fact = stored_session(session_id)
  if fact then
    return public_session(fact)
  end
  -- A session pi has not yet written to disk is only known to the process.
  local pi_state = current_state(connection)
  if pi_state.sessionId ~= session_id then
    error('Pi session not found: ' .. session_id, 0)
  end
  return live_session(pi_state)
end)

M.create_session = Promise.async(function(connection, location)
  revive():await()
  local client = process.get()
  if client:new_session():await().cancelled then
    error('Pi refused to start a new session', 0)
  end
  return live_session(current_state(connection), location)
end)

---Pages are never partial: pi returns the whole transcript, so there is no older cursor.
M.list_messages = Promise.async(function(connection, session_id)
  if current_state(connection).sessionId == session_id then
    return { data = process.get():get_messages():await().messages, cursor = {} }
  end
  local fact = stored_session(session_id)
  if not fact then
    error('Pi session not found: ' .. session_id, 0)
  end
  return { data = sessions.read_messages(fact.path), cursor = {} }
end)

---@param input OpencodeV2SubmitInput
---@return string
local function prompt_text(input)
  local blocks = {}
  for _, context in ipairs(input.context or {}) do
    if context.text ~= '' then
      blocks[#blocks + 1] = context.text
    end
  end
  if #blocks == 0 then
    return input.text
  end
  return table.concat({ '<context>', table.concat(blocks, '\n\n'), '</context>', '', input.text }, '\n')
end

M.submit = Promise.async(function(connection, session_id, input)
  revive():await()
  ensure_active(connection, session_id)
  local model = input.model
  apply_selection(model and model.providerID, model and model.modelID, input.variant)
  process.get():prompt(prompt_text(input)):await()
  return { id = input.id or id.ascending('message') }
end)

M.interrupt = Promise.async(function(connection, session_id)
  if current_state(connection).sessionId ~= session_id then
    return false
  end
  process.get():abort():await()
  return true
end)

---@param connection OpencodePiConnection
---@param session_id string
---@param model OpencodeV2ModelInput
M.set_session_model = Promise.async(function(connection, session_id, model)
  ensure_active(connection, session_id)
  apply_selection(model.providerID, model.id, model.variant)
  return true
end)

M.set_thinking_level = Promise.async(function(_, level)
  process.get():set_thinking_level(level):await()
  return level
end)

M.cycle_thinking_level = Promise.async(function()
  local result = process.get():cycle_thinking_level():await()
  if not result.level then
    error('Current model does not support thinking levels', 0)
  end
  return result.level
end)

M.cycle_model = Promise.async(function()
  local result = process.get():cycle_model():await()
  if not result.model then
    error('No other model to cycle to', 0)
  end
  return { providerID = result.model.provider, id = result.model.id, variant = result.thinkingLevel }
end)

---@return Promise<OpencodePiModel[]>
local function available_models()
  return process.get():get_available_models():and_then(function(data)
    return data.models
  end)
end

function M.list_models()
  return available_models():and_then(catalog.models)
end

function M.list_providers(_, location)
  return available_models():and_then(function(models)
    return { location = location, data = catalog.providers(models) }
  end)
end

M.get_model_catalog = Promise.async(function()
  local models = available_models():await()
  return catalog.catalog(models, process.get():get_state():await().model)
end)

M.get_default_model = Promise.async(function()
  return catalog.current_model(process.get():get_state():await())
end)

M.get_config = Promise.async(function()
  local model = catalog.current_model(process.get():get_state():await())
  return { model = model and (model.providerID .. '/' .. model.id), agent = {} }
end)

---@return Promise<OpencodePiCommand[]>
local function available_commands()
  return process.get():get_commands():and_then(function(data)
    return data.commands
  end)
end

function M.list_commands()
  return available_commands():and_then(catalog.commands)
end

function M.list_skills()
  return available_commands():and_then(catalog.skills)
end

function M.get_user_commands()
  return available_commands():and_then(catalog.user_commands)
end

---Pi runs slash commands (extensions, templates, skills) itself when they lead a prompt.
M.send_command = Promise.async(function(connection, session_id, _, input)
  revive():await()
  ensure_active(connection, session_id)
  local provider, model_id
  if input.model then
    provider, model_id = input.model:match('^(.-)/(.+)$')
    if not provider then
      error('Pi send_command model must use provider/model format', 0)
    end
  end
  apply_selection(provider, model_id, input.variant)
  local text = '/' .. input.command
  if input.arguments and input.arguments ~= '' then
    text = text .. ' ' .. input.arguments
  end
  process.get():prompt(text):await()
  return true
end)

M.rename_session = Promise.async(function(connection, session_id, _, title)
  if title == '' then
    error('Session title cannot be empty', 0)
  end
  ensure_active(connection, session_id)
  process.get():set_session_name(title):await()
  local observation = connection.observations[session_id]
  if observation then
    observation:read().session.title = title
    observation:_event_changed('session')
  end
  return true
end)

M.summarize_session = Promise.async(function(connection, session_id)
  ensure_active(connection, session_id)
  process.get():compact():await()
  return { id = id.ascending('message') }
end)

---Pi forks by entry id and knows nothing of this client's message ids, so the Nth user message maps to the Nth fork point.
---@param session_id string
---@param message_id string
---@param connection OpencodePiConnection
---@return string
local function fork_entry_id(connection, session_id, message_id)
  local observation = connection.observations[session_id]
  if not observation then
    error('Pi cannot fork a session that is not observed', 0)
  end
  local state = observation:read()
  local ordinal = 0
  local found
  for _, entry_id in ipairs(state.entry_order) do
    local entry = state.entries_by_id[entry_id] --[[@as table]]
    if entry.kind == 'user' then
      ordinal = ordinal + 1
    end
    if entry_id == message_id then
      found = ordinal
      break
    end
  end
  local target = found and process.get():get_fork_messages():await().messages[found]
  if not target then
    error('Pi has no fork point for message ' .. message_id, 0)
  end
  return target.entryId
end

M.fork_session = Promise.async(function(connection, session_id, location, input)
  ensure_active(connection, session_id)
  local client = process.get()
  local request = input and input.messageID and client:fork(fork_entry_id(connection, session_id, input.messageID))
    or client:clone()
  if request:await().cancelled then
    error('Pi refused to fork the session', 0)
  end
  return live_session(current_state(connection), location)
end)

---Adapts pi's JSONL events to the SSE framing the shared observation lifecycle consumes.
function M.subscribe_events(_, on_chunk)
  local unsubscribe = process.on_event(function(event)
    on_chunk('data: ' .. vim.json.encode(event) .. '\n\n')
  end)
  return { shutdown = unsubscribe }
end

---@param value any
---@return Promise<any>
local function resolved(value)
  return Promise.new():resolve(value)
end

---Capabilities with nothing to report, or a fixed answer, for callers that expect a value.
---@type table<string, fun(): any>
local empty = {
  list_active_sessions = function()
    return {}
  end,
  list_inbox = function()
    return {}
  end,
  list_permissions = function()
    return {}
  end,
  list_questions = function()
    return {}
  end,
  list_agents = function()
    return { { id = 'pi', mode = 'primary' } }
  end,
  -- The UI requires a primary agent; pi has a single behavior, not switchable modes.
  list_primary_agents = function()
    return { 'pi' }
  end,
  list_subagents = function()
    return {}
  end,
  list_mcp_servers = function()
    return {}
  end,
  find_files = function()
    return {}
  end,
  get_file_status = function()
    return {}
  end,
  get_current_project = function()
    return { id = 'pi' }
  end,
}

for name, produce in pairs(empty) do
  M[name] = function()
    return resolved(produce())
  end
end

for _, name in ipairs({
  'delete_session',
  'revert_message',
  'unrevert_messages',
  'diff_session',
  'set_session_agent',
  'activate_skill',
  'reply_permission',
  'reply_question',
  'cancel_question',
  'connect_mcp',
  'disconnect_mcp',
}) do
  M[name] = function()
    return Promise.new():reject('Pi does not support ' .. name)
  end
end

for _, name in ipairs({ 'init_session', 'share_session', 'unshare_session' }) do
  M[name] = function()
    error('Pi does not support ' .. name, 0)
  end
end

return M
