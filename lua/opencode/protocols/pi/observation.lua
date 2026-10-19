local lifecycle = require('opencode.protocols.observation')
local entries = require('opencode.protocols.entries')
local submission = require('opencode.protocols.submission')
local normalize = require('opencode.protocols.pi.normalize')
local stream = require('opencode.protocols.pi.stream')
local process = require('opencode.protocols.pi.process')
local id = require('opencode.id')
local ui_requests = require('opencode.protocols.pi.ui_requests')
local Promise = require('opencode.promise')

local M = {}

local UNSUPPORTED = 'Pi has no equivalent'

---@param observation OpencodePiObservation
---@param event_type string
---@param properties? table
local function emit(observation, event_type, properties)
  vim.api.nvim_exec_autocmds('User', {
    pattern = 'OpencodeEvent:' .. event_type,
    data = {
      event = {
        type = event_type,
        properties = vim.tbl_extend('force', properties or {}, { sessionID = observation._session_id }),
      },
    },
  })
end

---@class OpencodePiObservation: OpencodeObservation
---@field _connection OpencodePiConnection
---@field _pi_pending_inputs {id: string, text: string}[] Inputs awaiting the user message pi echoes back
---@field _pi_queued {id: string, text: string}[] Steer/follow-up messages pi holds until the agent consumes them
---@field _pi_ended boolean The current run was already finished by an earlier event
---@field _pi_ui table<string, OpencodePiUiRequest> Open extension dialogs by request id
---@field _pi_admissions table<string, fun(value?: table, err?: string)>
---@field _pi_partial? OpencodePiMessage Assistant message rebuilt from message_update deltas
---@field _pi_live table<string, string> Entry id of the message currently streaming, per role; pi snapshots carry no id
---@field _pi_notices table[] Run notices (retry, compaction, extension errors) that are not part of pi's transcript
---@field _pi_stop? {reason?: string, message?: string} How the latest assistant message ended
---@field submit fun(self: OpencodePiObservation, input: OpencodeV2SubmitInput, selected?: table, on_input_id?: fun(id: string)): Promise<OpencodeSubmission>
---@field interrupt fun(self: OpencodePiObservation): Promise<boolean>
---@field load_older fun(self: OpencodePiObservation): Promise<nil>
---@field reply_permission fun(self: OpencodePiObservation, request_id: string, answer: {choice: 'once'|'always'|'reject', message?: string}): Promise<boolean>
---@field reply_question fun(self: OpencodePiObservation, request_id: string, answers: table<string, any>): Promise<boolean>
---@field reject_question fun(self: OpencodePiObservation, request_id: string): Promise<boolean>
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
---@param queued {id: string, text: string}
---@return table
local function queued_entry(observation, queued)
  local entry = {
    id = queued.id,
    session_id = observation._session_id,
    kind = 'user',
    queued = true,
    time = { created = vim.uv.now() },
    content = { { kind = 'text', text = queued.text } },
  }
  normalize.assign_content_ids(entry)
  return entry
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
  for _, queued in ipairs(observation._pi_queued) do
    by_id[queued.id] = queued_entry(observation, queued)
    order[#order + 1] = queued.id
  end
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

---Extension dialogs are produced by events, never fetched.
---@param resource OpencodeObservedResource
---@return boolean
local function local_resource(resource)
  return resource == 'permissions' or resource == 'questions'
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

---Pi echoes the prompt after wrapping it with context, so a suffix match is the same input.
---@param observation OpencodePiObservation
---@param text string
---@return string? id
local function take_pending(observation, text)
  local pending = observation._pi_pending_inputs
  for index, input in ipairs(pending) do
    if input.text == text or vim.endswith(text, input.text) then
      return table.remove(pending, index).id
    end
  end
  local first = table.remove(pending, 1)
  return first and first.id
end

---@param observation OpencodePiObservation
---@param queued_id string
local function drop_queued(observation, queued_id)
  local state = observation:read()
  for index, queued in ipairs(observation._pi_queued) do
    if queued.id == queued_id then
      table.remove(observation._pi_queued, index)
      state.entries_by_id[queued_id] = nil
      state.entry_order = vim.tbl_filter(function(entry_id)
        return entry_id ~= queued_id
      end, state.entry_order)
      return
    end
  end
end

---Queued input has not reached the transcript yet, so it always trails the real entries.
---@param observation OpencodePiObservation
local function trail_queued(observation)
  local state = observation:read()
  local queued_ids = {}
  for _, queued in ipairs(observation._pi_queued) do
    queued_ids[queued.id] = true
  end
  local order = vim.tbl_filter(function(entry_id)
    return not queued_ids[entry_id]
  end, state.entry_order)
  for _, queued in ipairs(observation._pi_queued) do
    order[#order + 1] = queued.id
  end
  state.entry_order = order
end

---@param observation OpencodePiObservation
---@param steering string[]
---@param follow_up string[]
local function set_queue(observation, steering, follow_up)
  local state = observation:read()
  local previous = observation._pi_queued
  local texts = vim.list_extend(vim.list_slice(steering), follow_up)
  local queue = {}
  local reusable = vim.list_slice(previous)
  for _, text in ipairs(texts) do
    local found
    for index, queued in ipairs(reusable) do
      if queued.text == text then
        found = table.remove(reusable, index)
        break
      end
    end
    if not found then
      local pending
      for _, input in ipairs(observation._pi_pending_inputs) do
        local taken = vim.tbl_contains(
          vim.tbl_map(function(q)
            return q.id
          end, queue),
          input.id
        )
        if not taken and (input.text == text or vim.endswith(text, input.text)) then
          pending = input
          break
        end
      end
      found = { id = pending and pending.id or id.ascending('message'), text = text }
    end
    queue[#queue + 1] = found
  end
  for _, gone in ipairs(reusable) do
    state.entries_by_id[gone.id] = nil
  end
  observation._pi_queued = queue
  for _, queued in ipairs(queue) do
    local existing = state.entries_by_id[queued.id]
    state.entries_by_id[queued.id] = entries.replace(existing, queued_entry(observation, queued)) --[[@as OpencodeMessage]]
    if not existing then
      state.entry_order[#state.entry_order + 1] = queued.id
    end
  end
  local kept = {}
  for _, entry_id in ipairs(state.entry_order) do
    if state.entries_by_id[entry_id] then
      kept[#kept + 1] = entry_id
    end
  end
  state.entry_order = kept
  trail_queued(observation)
  observation:_event_changed('messages')
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
      entry.id = take_pending(observation, entry.content[1].text) or entry.id
      normalize.assign_content_ids(entry)
      drop_queued(observation, entry.id)
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
  trail_queued(observation)
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
  observation._pi_live, observation._pi_stop, observation._pi_ended = {}, nil, true
  emit(observation, 'session.execution.' .. outcome, { error = err })
  local pending = observation._pi_admissions
  observation._pi_admissions = {}
  for _, finish in pairs(pending) do
    finish({ kind = 'session_idle', outcome = outcome, idle_at = vim.uv.now(), error = err })
  end
end

---@param observation OpencodePiObservation
local function settle(observation)
  local stop = observation._pi_stop
  if stop and stop.reason == 'aborted' then
    finish_run(observation, 'interrupted')
  elseif stop and stop.reason == 'error' then
    finish_run(observation, 'failed', { message = stop.message or 'Pi stopped with an error' })
  else
    finish_run(observation, 'succeeded')
  end
end

---@param kind 'permission'|'question'
---@return OpencodeObservedResource
local function dialog_resource(kind)
  return kind == 'permission' and 'permissions' or 'questions'
end

---@param options {value: any}[]
---@param value any
---@return boolean
local function has_option(options, value)
  for _, option in ipairs(options) do
    if option.value == value then
      return true
    end
  end
  return false
end

---@param observation OpencodePiObservation
---@param request_id string
---@param how 'replied'|'cancelled'
---@param answer? any
local function close_dialog(observation, request_id, how, answer)
  local dialog = observation._pi_ui[request_id]
  if not dialog then
    return
  end
  observation._pi_ui[request_id] = nil
  local state = observation:read()
  if dialog.kind == 'permission' then
    state.permission_requests_by_id[request_id] = nil
    emit(observation, 'permission.replied', { requestID = request_id, reply = answer })
  else
    state.question_requests_by_id[request_id] = nil
    emit(observation, how == 'replied' and 'form.replied' or 'form.cancelled', { id = request_id, answer = answer })
  end
  observation:_event_changed(dialog_resource(dialog.kind))
end

---@param observation OpencodePiObservation
---@param event table `extension_ui_request` for a dialog method
local function open_dialog(observation, event)
  local kind = ui_requests.dialog_kind(event.method) --[[@as 'permission'|'question']]
  local state = observation:read()
  observation._pi_ui[event.id] = { kind = kind, method = event.method }
  if kind == 'permission' then
    state.permission_requests_by_id[event.id] = ui_requests.permission(event, observation._session_id)
    emit(observation, 'permission.asked', { id = event.id })
  else
    state.question_requests_by_id[event.id] = ui_requests.question(event, observation._session_id)
    emit(observation, 'form.created', { id = event.id })
  end
  observation:_event_changed(dialog_resource(kind))
  if type(event.timeout) == 'number' then
    -- Pi resolves a timed-out dialog itself and sends nothing, so only the local prompt needs to go.
    vim.defer_fn(function()
      close_dialog(observation, event.id, 'cancelled')
    end, math.floor(event.timeout))
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
  trail_queued(observation)
  observation:_event_changed('messages')
end

---@param observation OpencodePiObservation
---@param retry {attempt?: integer, message?: string, scheduled_at?: number}
local function set_retrying(observation, retry)
  local execution = observation:read().execution
  execution.activity = 'retrying'
  execution.retry = vim.tbl_extend('force', execution.retry or {}, retry)
  observation:_event_changed('execution')
  emit(observation, 'session.retry.scheduled', {
    attempt = execution.retry.attempt,
    at = execution.retry.scheduled_at,
    message = execution.retry.message,
  })
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
    observation._pi_stop, observation._pi_ended = nil, false
    set_activity(observation)
    emit(observation, 'session.execution.started')
  end,
  agent_end = function(observation, event)
    if event.willRetry then
      set_retrying(observation, {})
    elseif not observation._pi_ended and #observation._pi_queued == 0 then
      -- agent_settled is not guaranteed after a failed retry; a queued message restarts the run itself.
      settle(observation)
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
    if not observation._pi_ended then
      settle(observation)
    end
  end,
  queue_update = function(observation, event)
    set_queue(observation, event.steering or {}, event.followUp or {})
  end,
  extension_ui_request = function(observation, event)
    -- Everything but dialogs is handled for the whole connection, observed or not.
    if ui_requests.dialog_kind(event.method) then
      open_dialog(observation, event)
    end
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
    if observation._pi_ended then
      observation._pi_ended = false
      return
    end
    settle(observation)
  end,
  message_start = function(observation, event)
    observation._pi_partial = event.message.role == 'assistant' and vim.deepcopy(event.message) or nil
    message_event(observation, event.message, 'start')
  end,
  message_update = function(observation, event)
    local partial = observation._pi_partial
    if partial and stream.apply(partial, event.assistantMessageEvent) then
      message_event(observation, partial, 'update')
    end
  end,
  message_end = function(observation, event)
    if event.message.role == 'assistant' then
      observation._pi_partial = nil
    end
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
    for request_id in pairs(vim.deepcopy(observation._pi_ui)) do
      close_dialog(observation, request_id, 'cancelled')
    end
    if #observation._pi_queued > 0 then
      set_queue(observation, {}, {})
    end
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
    self._pi_pending_inputs[#self._pi_pending_inputs + 1] = { id = input_id, text = input.text }
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
          return pending.id ~= input_id
        end, self._pi_pending_inputs)
        return Promise.new():reject(failure)
      end)
      :finally(finish_operation)
  end

  function observation:reply_permission(request_id, answer)
    local request = self:read().permission_requests_by_id[request_id]
    if not request or request.status ~= 'pending' then
      error('permission request is not pending', 0)
    end
    if not has_option(request.choices, answer.choice) then
      error('invalid permission answer', 0)
    end
    return self
      :_start_action(self._connection.operations.reply_permission, self._session_id, request_id, {
        reply = answer.choice,
        message = answer.message,
      })
      :and_then(function(replied)
        close_dialog(self, request_id, 'replied', answer.choice)
        return replied
      end)
  end

  function observation:reply_question(request_id, answers)
    local request = self:read().question_requests_by_id[request_id]
    if not request or request.status ~= 'pending' then
      error('question request is not answerable', 0)
    end
    local field = request.fields[1] --[[@as OpencodeQuestionInfo]]
    local value = answers[field.key]
    if type(value) ~= 'string' or vim.tbl_count(answers) ~= 1 then
      error('invalid answer for question field ' .. field.key, 0)
    end
    if not field.custom and not has_option(field.options, value) then
      error('invalid answer for question field ' .. field.key, 0)
    end
    return self
      :_start_action(self._connection.operations.reply_question, self._session_id, request_id, answers)
      :and_then(function(replied)
        close_dialog(self, request_id, 'replied', value)
        return replied
      end)
  end

  function observation:reject_question(request_id)
    local request = self:read().question_requests_by_id[request_id]
    if not request or request.status ~= 'pending' then
      error('question request is not pending', 0)
    end
    return self
      :_start_action(self._connection.operations.cancel_question, self._session_id, request_id)
      :and_then(function(cancelled)
        close_dialog(self, request_id, 'cancelled')
        return cancelled
      end)
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
  for _, resource in ipairs({ 'children', 'inbox', 'files' }) do
    unsupported[resource] = UNSUPPORTED
  end

  local observation = lifecycle.attach(connection, session, lifecycle.new_state(session, unsupported), {
    name = 'Pi',
    request_resource = request_resource,
    apply_resource = apply_resource,
    route_event = route_event,
    local_resource = local_resource,
    on_release_resource = function(current, resource)
      ---@cast current OpencodePiObservation
      for request_id, dialog in pairs(vim.deepcopy(current._pi_ui)) do
        if dialog_resource(dialog.kind) == resource then
          -- The prompt is gone with its watcher; leaving Pi's dialog open would block the extension forever.
          current._pi_ui[request_id] = nil
          process.get():extension_ui_response({ id = request_id, cancelled = true })
        end
      end
    end,
    refresh_after_event = function()
      return false
    end,
  })
  ---@cast observation OpencodePiObservation
  observation._pi_pending_inputs = {}
  observation._pi_admissions = {}
  observation._pi_live = {}
  observation._pi_notices = {}
  observation._pi_queued = {}
  observation._pi_ended = false
  observation._pi_ui = {}
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
