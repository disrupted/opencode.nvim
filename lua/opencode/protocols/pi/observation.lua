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
---@field _pi_live table<string, string> Entry id of the message currently streaming, per role; pi snapshots carry no id
---@field _pi_notices table[] Run notices (retry, compaction, extension errors) that are not part of pi's transcript
---@field _pi_stop? {reason?: string, message?: string} How the latest assistant message ended
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
  for _, notice in ipairs(observation._pi_notices) do
    by_id[notice.id] = notice
    order[#order + 1] = notice.id
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
---@return table<string, table?>
local function tool_parts(observation)
  local state = observation:read()
  return normalize.index_tool_parts(vim.tbl_map(function(entry_id)
    return state.entries_by_id[entry_id]
  end, state.entry_order))
end

---@param observation OpencodePiObservation
---@param message OpencodePiMessage
---@param phase 'start'|'update'|'end'
local function message_event(observation, message, phase)
  if message.role == 'toolResult' then
    local part = tool_parts(observation)[
      message.toolCallId --[[@as string]]
    ]
    if part then
      normalize.apply_tool_result(part, message)
      observation:_event_changed('messages')
      return
    end
  end

  local role = message.role
  if phase == 'start' then
    observation._pi_live[role] = nil
  end
  local live_id = observation._pi_live[role]
  local entry = normalize.entry(message, observation._session_id, #observation:read().entry_order + 1, live_id)
  if not entry then
    return
  end
  if not live_id then
    if role == 'user' then
      -- The prompt was shown under the id this client generated; keep that identity.
      entry.id = table.remove(observation._pi_pending_inputs, 1) or entry.id
      normalize.assign_content_ids(entry)
    end
    observation._pi_live[role] = entry.id
  end
  if phase == 'end' then
    observation._pi_live[role] = nil
    if role == 'assistant' then
      observation._pi_stop = { reason = message.stopReason, message = message.errorMessage }
    end
  end
  put_entry(observation, entry)
  observation:_event_changed('messages')
end

---@param observation OpencodePiObservation
---@param event table
local function tool_event(observation, event)
  local part = tool_parts(observation)[event.toolCallId]
  if part then
    normalize.apply_tool_execution(part, event)
    observation:_event_changed('messages')
  end
end

---@param observation OpencodePiObservation
---@param outcome? 'succeeded'|'failed'|'interrupted' Set when the run ended
---@param err? {message: string}
local function set_activity(observation, outcome, err)
  local execution = observation:read().execution
  execution.activity = outcome and 'idle' or 'running'
  execution.retry = nil
  if outcome then
    execution.last_outcome, execution.error, execution.last_idle = outcome, err, vim.uv.now()
  end
  observation:_event_changed('execution')
end

---@param observation OpencodePiObservation
---@param outcome 'succeeded'|'failed'|'interrupted'
---@param err? {message: string}
local function finish_run(observation, outcome, err)
  set_activity(observation, outcome, err)
  observation._pi_live, observation._pi_stop = {}, nil
  local pending = observation._pi_admissions
  observation._pi_admissions = {}
  for _, finish in pairs(pending) do
    finish({ kind = 'session_idle', outcome = outcome, idle_at = vim.uv.now(), error = err })
  end
end

---@param observation OpencodePiObservation
---@param text string
local function add_notice(observation, text)
  local entry = {
    id = id.ascending('message'),
    session_id = observation._session_id,
    kind = 'assistant',
    agent = 'pi',
    time = { created = vim.uv.now() },
    content = { { kind = 'text', text = text } },
  }
  normalize.assign_content_ids(entry)
  observation._pi_notices[#observation._pi_notices + 1] = entry
  put_entry(observation, entry)
  observation:_event_changed('messages')
end

---@param observation OpencodePiObservation
---@param retry {attempt?: integer, message?: string, scheduled_at?: number}
local function set_retrying(observation, retry)
  local execution = observation:read().execution
  execution.activity = 'retrying'
  execution.retry = vim.tbl_extend('force', execution.retry or {}, retry)
  observation:_event_changed('execution')
end

---@param event table `compaction_end`
---@return string
local function compaction_text(event)
  if event.errorMessage then
    return 'Compaction failed: ' .. event.errorMessage
  end
  if event.aborted then
    return 'Compaction aborted'
  end
  local summary = event.result and event.result.summary
  return summary and ('Compaction complete\n\n' .. summary) or 'Compaction complete'
end

---@type table<string, (fun(observation: OpencodePiObservation, event: table))?>
local handlers = {
  agent_start = function(observation)
    observation._pi_stop = nil
    set_activity(observation)
  end,
  agent_end = function(observation, event)
    if event.willRetry then
      set_retrying(observation, {})
    end
  end,
  auto_retry_start = function(observation, event)
    set_retrying(observation, {
      attempt = event.attempt,
      message = event.errorMessage,
      scheduled_at = event.delayMs and (vim.uv.now() + event.delayMs) or nil,
    })
  end,
  auto_retry_end = function(observation, event)
    if event.success then
      set_activity(observation)
      return
    end
    local message = 'Pi retry failed: ' .. tostring(event.finalError or 'unknown error')
    observation._pi_stop = { reason = 'error', message = message }
    add_notice(observation, message)
  end,
  compaction_start = function(observation, event)
    if event.reason == 'manual' then
      set_activity(observation)
    end
  end,
  compaction_end = function(observation, event)
    local failed = event.errorMessage ~= nil
    add_notice(observation, compaction_text(event))
    if not failed and not event.aborted then
      observation:_start_resource('messages')
    end
    if event.willRetry then
      set_retrying(observation, {})
    elseif event.reason == 'manual' then
      local outcome = failed and 'failed' or (event.aborted and 'interrupted' or 'succeeded')
      set_activity(observation, outcome, failed and { message = event.errorMessage } or nil)
    end
  end,
  extension_error = function(observation, event)
    local where = event.extensionPath and (' (' .. event.extensionPath .. ')') or ''
    add_notice(observation, 'Pi extension error' .. where .. ': ' .. tostring(event.error or 'unknown error'))
  end,
  agent_settled = function(observation)
    local stop = observation._pi_stop
    if stop and stop.reason == 'aborted' then
      finish_run(observation, 'interrupted')
    elseif stop and stop.reason == 'error' then
      finish_run(observation, 'failed', { message = stop.message or 'Pi stopped with an error' })
    else
      finish_run(observation, 'succeeded')
    end
  end,
  message_start = function(observation, event)
    message_event(observation, event.message, 'start')
  end,
  message_update = function(observation, event)
    message_event(observation, event.message, 'update')
  end,
  message_end = function(observation, event)
    message_event(observation, event.message, 'end')
  end,
  tool_execution_start = tool_event,
  tool_execution_update = tool_event,
  tool_execution_end = tool_event,
  process_exit = function(observation, event)
    if event.expected then
      return
    end
    local message = ('Pi process exited unexpectedly (code %s)'):format(tostring(event.code))
    finish_run(observation, 'failed', { message = message })
    observation._pi_pending_inputs = {}
  end,
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
  local observation = connection.observations[
    connection.pi.session_id --[[@as string]]
  ]
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
  observation._pi_live = {}
  observation._pi_notices = {}
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
