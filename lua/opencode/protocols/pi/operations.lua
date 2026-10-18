local Promise = require('opencode.promise')
local id = require('opencode.id')
local process = require('opencode.protocols.pi.process')
local sessions = require('opencode.protocols.pi.sessions')

---Pi mirrors the v2 operation surface so shared callers need no protocol branches.
---@diagnostic disable-next-line: missing-fields
local M = {} --[[@as OpencodeV2Operations]]

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
  ensure_active(connection, session_id)
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
  list_models = function()
    return {}
  end,
  list_commands = function()
    return {}
  end,
  list_skills = function()
    return {}
  end,
  -- The UI requires a primary agent; pi has a single behavior, not switchable modes.
  list_primary_agents = function()
    return { 'pi' }
  end,
  list_subagents = function()
    return {}
  end,
  get_user_commands = function()
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
  get_default_model = function()
    return nil
  end,
  get_config = function()
    return { agent = {} }
  end,
  list_providers = function()
    return { location = { directory = vim.fn.getcwd() }, data = {} }
  end,
  get_model_catalog = function()
    return { providers = {}, default = {} }
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
  'rename_session',
  'summarize_session',
  'fork_session',
  'revert_message',
  'unrevert_messages',
  'diff_session',
  'set_session_agent',
  'set_session_model',
  'send_command',
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
