local lifecycle = require('opencode.protocols.observation')
local entries = require('opencode.protocols.entries')
local submission = require('opencode.protocols.submission')
local normalize = require('opencode.protocols.pi.normalize')
local process = require('opencode.protocols.pi.process')
local id = require('opencode.id')
local Promise = require('opencode.promise')

local M = {}

local UNSUPPORTED = 'Pi has no equivalent'

---@class OpencodePiObservation: OpencodeObservation
---@field _connection OpencodePiConnection
---@field _pi_pending_inputs string[] Input ids awaiting the user message pi echoes back
---@field _pi_admissions table<string, fun(value?: table, err?: string)>
---@field submit fun(self: OpencodePiObservation, input: OpencodeV2SubmitInput, selected?: table, on_input_id?: fun(id: string)): Promise<OpencodeSubmission>
---@field interrupt fun(self: OpencodePiObservation): Promise<boolean>
---@field load_older fun(self: OpencodePiObservation): Promise<nil>
---@field load_complete_history fun(self: OpencodePiObservation): Promise<nil>

---@param observation OpencodePiObservation
---@param entry table
local function put_entry(observation, entry)
  local state = observation:read()
  local existing = state.entries_by_id[entry.id]
  normalize.carry_tool_state(entry, existing)
  state.entries_by_id[entry.id] = entries.replace(existing, entry) --[[@as OpencodeMessage]]
  if not existing then
    state.entry_order[#state.entry_order + 1] = entry.id
  end
end

---@param observation OpencodePiObservation
---@param messages OpencodePiMessage[]
local function apply_messages(observation, messages)
  local state = observation:read()
  local by_id, order = {}, {}
  for _, entry in ipairs(normalize.entries(messages, observation._session_id)) do
    by_id[entry.id] = entries.replace(state.entries_by_id[entry.id], entry)
    order[#order + 1] = entry.id
  end
  state.entries_by_id, state.entry_order = by_id, order
end

---@param observation OpencodePiObservation
---@param resource OpencodeObservedResource
---@param value any
local function apply_resource(observation, resource, value)
  local state = observation:read()
  if resource == 'session' then
    state.session = value
  elseif resource == 'messages' then
    apply_messages(observation, value.data)
  elseif resource == 'execution' then
    state.execution.activity = value[observation._session_id] and 'running' or 'idle'
  end
end

---@param observation OpencodePiObservation
---@param resource OpencodeObservedResource
---@return Promise<any>
local function request_resource(observation, resource)
  local operations = observation._connection.operations
  if resource == 'session' then
    return operations.get_session(observation._connection, observation._session_id)
  elseif resource == 'messages' then
    return operations.list_messages(observation._connection, observation._session_id)
  end
  return process.get():get_state():and_then(function(pi_state)
    return pi_state.isStreaming and { [observation._session_id] = { type = 'running' } } or {}
  end)
end

---@param observation OpencodePiObservation
---@param message OpencodePiMessage
local function message_event(observation, message)
  local index = #observation:read().entry_order + 1
  local entry = normalize.entry(message, observation._session_id, index)
  if not entry then
    return
  end
  if message.role == 'user' then
    -- The prompt was shown under the id this client generated; keep that identity.
    entry.id = table.remove(observation._pi_pending_inputs, 1) or entry.id
  end
  put_entry(observation, entry)
  observation:_event_changed('messages')
end

---@param observation OpencodePiObservation
---@param event table
local function tool_event(observation, event)
  local state = observation:read()
  local part = normalize.index_tool_parts(vim.tbl_map(function(entry_id)
    return state.entries_by_id[entry_id]
  end, state.entry_order))[event.toolCallId]
  if part then
    normalize.apply_tool_execution(part, event)
    observation:_event_changed('messages')
  end
end

---@param observation OpencodePiObservation
---@param running boolean
local function set_activity(observation, running)
  local execution = observation:read().execution
  execution.activity = running and 'running' or 'idle'
  if not running then
    execution.last_outcome = 'succeeded'
    execution.last_idle = vim.uv.now()
  end
  observation:_event_changed('execution')
end

---@type table<string, (fun(observation: OpencodePiObservation, event: table))?>
local handlers = {
  agent_start = function(observation)
    set_activity(observation, true)
  end,
  agent_settled = function(observation)
    set_activity(observation, false)
    local pending = observation._pi_admissions
    observation._pi_admissions = {}
    for _, finish in pairs(pending) do
      finish({ kind = 'session_idle', outcome = 'succeeded', idle_at = vim.uv.now() })
    end
  end,
  message_start = function(observation, event)
    message_event(observation, event.message)
  end,
  message_update = function(observation, event)
    message_event(observation, event.message)
  end,
  message_end = function(observation, event)
    if event.message.role ~= 'toolResult' then
      message_event(observation, event.message)
    end
  end,
  tool_execution_start = tool_event,
  tool_execution_update = tool_event,
  tool_execution_end = tool_event,
  session_info_changed = function(observation, event)
    local session = observation:read().session
    session.title = event.name
    observation:_event_changed('session')
  end,
}

---Pi events carry no session id: they belong to the process's single active session.
---@param connection OpencodePiConnection
---@param event table
local function route_event(connection, event)
  local observation = connection.observations[connection.pi.session_id --[[@as string]]]
  local handler = handlers[event.type]
  if observation and handler then
    ---@cast observation OpencodePiObservation
    handler(observation, event)
  end
end

---@param observation OpencodePiObservation
local function attach_actions(observation)
  function observation:submit(input, _, on_input_id)
    local input_id = input.id or id.ascending('message')
    input = vim.tbl_extend('force', {}, input, { id = input_id })
    if on_input_id then
      on_input_id(input_id)
    end
    local finish_operation = self:_begin_local_operation()
    local ok, err = pcall(lifecycle.ensure_stream, self._connection, self)
    if not ok then
      finish_operation()
      error(err, 0)
    end
    self._pi_pending_inputs[#self._pi_pending_inputs + 1] = input_id
    return self._connection.operations
      .submit(self._connection, self._session_id, input)
      :and_then(function(admission)
        local release = self:_begin_local_operation()
        local handle, complete = submission.new({ kind = 'accepted', input = vim.deepcopy(admission) }, function()
          self._pi_admissions[admission.id] = nil
          release()
        end)
        self._pi_admissions[admission.id] = complete
        return handle
      end)
      :catch(function(failure)
        self._pi_pending_inputs = vim.tbl_filter(function(pending)
          return pending ~= input_id
        end, self._pi_pending_inputs)
        return Promise.new():reject(failure)
      end)
      :finally(finish_operation)
  end

  function observation:interrupt()
    return self:_start_action(self._connection.operations.interrupt, self._session_id)
  end

  -- pi returns the whole transcript in one page.
  function observation:load_older()
    return Promise.new():resolve(nil)
  end
  observation.load_complete_history = observation.load_older
end

---@param connection OpencodePiConnection
---@param ref {id: string, location?: OpencodeLocation}
---@return OpencodePiObservation
function M.new(connection, ref)
  local session = { id = ref.id }
  if ref.location ~= nil then
    session.location = vim.deepcopy(ref.location)
  end

  local unsupported = {}
  for _, resource in ipairs({ 'children', 'inbox', 'permissions', 'questions', 'files' }) do
    unsupported[resource] = UNSUPPORTED
  end

  local observation = lifecycle.attach(connection, session, lifecycle.new_state(session, unsupported), {
    name = 'Pi',
    request_resource = request_resource,
    apply_resource = apply_resource,
    route_event = route_event,
    refresh_after_event = function()
      return false
    end,
  })
  ---@cast observation OpencodePiObservation
  observation._pi_pending_inputs = {}
  observation._pi_admissions = {}
  attach_actions(observation)
  return observation
end

---@param connection OpencodePiConnection
function M.close(connection)
  for _, observation in pairs(connection.observations) do
    ---@cast observation OpencodePiObservation
    for _, finish in pairs(observation._pi_admissions) do
      finish(nil, 'connection closed')
    end
  end
  lifecycle.close(connection)
end

return M
