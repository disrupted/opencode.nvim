-- Speaks pi's RPC JSONL over stdio. Never touches real pi data: sessions come from files the test wrote.
local function read_json(path)
  local file = assert(io.open(path, 'r'))
  local text = file:read('*a')
  file:close()
  return vim.json.decode(text)
end

local script = read_json(assert(os.getenv('FAKE_PI_SCRIPT')))
local log_path = os.getenv('FAKE_PI_LOG')

local function append_log(record)
  if not log_path then
    return
  end
  local file = assert(io.open(log_path, 'a'))
  file:write(vim.json.encode(record), '\n')
  file:close()
end

local function write(text)
  io.stdout:write(text)
  io.stdout:flush()
end

local function send(record)
  write(vim.json.encode(record) .. '\n')
end

local function already_launched()
  if not log_path then
    return false
  end
  local file = io.open(log_path, 'r')
  if not file then
    return false
  end
  file:close()
  return true
end

-- A restarted pi forgets the live session and comes back on whatever it last persisted.
local initial = already_launched() and script.state_after_restart or script.state
local state = vim.tbl_extend('force', { sessionId = 'fake-session', isStreaming = false }, initial or {})
local messages = vim.deepcopy(script.messages or {})
local counts = {}
local new_sessions = 0
local models = script.models or {}
---@type string[]
local thinking_levels = { 'off', 'minimal', 'low', 'medium', 'high', 'xhigh' }

local function find_model(provider, id)
  for _, model in ipairs(models) do
    if model.provider == provider and model.id == id then
      return model
    end
  end
end

local function index_of(list, predicate)
  for i, item in ipairs(list) do
    if predicate(item) then
      return i
    end
  end
end

append_log({ argv = arg })

local function load_session(path)
  local file = io.open(path, 'r')
  if not file then
    return nil
  end
  local header, loaded = nil, {}
  for line in file:lines() do
    local ok, entry = pcall(vim.json.decode, line --[[@as string]])
    if ok and type(entry) == 'table' then
      if entry.type == 'session' and not header then
        header = entry
      elseif entry.type == 'message' then
        loaded[#loaded + 1] = entry.message
      end
    end
  end
  file:close()
  return header, loaded
end

local function track(event)
  if event.type == 'agent_start' then
    state.isStreaming = true
  elseif event.type == 'agent_settled' or event.type == 'agent_end' then
    state.isStreaming = false
  end
end

local function run(steps)
  for _, step in ipairs(steps or {}) do
    if step.event then
      track(step.event)
      send(step.event)
    elseif step.chunks then
      -- Splits one record across writes to exercise framing.
      for _, chunk in ipairs(step.chunks) do
        write(chunk)
        vim.uv.sleep(15)
      end
    elseif step.raw then
      write(step.raw)
    elseif step.sleep then
      vim.uv.sleep(step.sleep)
    elseif step.exit then
      os.exit(step.exit)
    end
  end
end

local function steps_for(command)
  counts[command.type] = (counts[command.type] or 0) + 1
  local runs = script.after_runs and script.after_runs[command.type]
  if runs then
    return runs[counts[command.type]]
  end
  return script.after and script.after[command.type]
end

local function handle(command)
  append_log(command)
  if command.type == 'extension_ui_response' then
    -- Like pi, dialog answers get no response; scripts can still react to them.
    run(steps_for(command))
    return
  end
  if script.silent and script.silent[command.type] then
    return
  end
  local reply = script.replies and script.replies[command.type]
  local data = reply and reply.data
  local failure = reply and reply.error

  if not failure and not data then
    if command.type == 'get_state' then
      data = vim.deepcopy(state)
    elseif command.type == 'get_messages' then
      data = { messages = messages }
    elseif command.type == 'switch_session' then
      local header, loaded = load_session(command.sessionPath)
      if script.cancel_switch then
        data = { cancelled = true }
      elseif not header then
        failure = 'no such session file: ' .. tostring(command.sessionPath)
      else
        state.sessionId, state.sessionFile, messages = header.id, command.sessionPath, loaded
        data = { cancelled = false }
      end
    elseif command.type == 'new_session' then
      new_sessions = new_sessions + 1
      state.sessionId, state.sessionFile, messages = 'fake-new-' .. new_sessions, nil, {}
      data = { cancelled = false }
    elseif command.type == 'prompt' or command.type == 'abort' then
      data = nil
    elseif command.type == 'get_available_models' then
      data = { models = models }
    elseif command.type == 'set_model' then
      local model = find_model(command.provider, command.modelId)
      if model then
        state.model, data = model, model
      else
        failure = 'unknown model: ' .. tostring(command.modelId)
      end
    elseif command.type == 'cycle_model' then
      -- With a single model pi answers with no data at all.
      if #models > 1 then
        local current = state.model
        local at = current
            and index_of(models, function(m)
              return m.provider == current.provider and m.id == current.id
            end)
          or 0
        state.model = models[at % #models + 1]
        data = { model = state.model, thinkingLevel = state.thinkingLevel or 'off', isScoped = false }
      end
    elseif command.type == 'set_thinking_level' then
      state.thinkingLevel = command.level
    elseif command.type == 'cycle_thinking_level' then
      if state.model and state.model.reasoning then
        local at = index_of(thinking_levels, function(level)
          return level == (state.thinkingLevel or 'off')
        end) or 0
        state.thinkingLevel = thinking_levels[at % #thinking_levels + 1]
        data = { level = state.thinkingLevel }
      end
    elseif command.type == 'get_commands' then
      data = { commands = script.commands or {} }
    elseif command.type == 'set_session_name' then
      state.sessionName = command.name
    elseif command.type == 'compact' then
      data = { summary = 'compacted', firstKeptEntryId = 'e1', tokensBefore = 1 }
    elseif command.type == 'get_fork_messages' then
      data = { messages = script.fork_messages or {} }
    elseif command.type == 'fork' or command.type == 'clone' then
      if script.cancel_fork then
        data = { cancelled = true }
      else
        new_sessions = new_sessions + 1
        state.sessionId, state.sessionFile, messages = 'fake-fork-' .. new_sessions, nil, {}
        data = { cancelled = false, text = command.type == 'fork' and 'forked text' or nil }
      end
    else
      failure = 'unknown command: ' .. tostring(command.type)
    end
  end

  send({
    type = 'response',
    id = command.id,
    command = command.type,
    success = failure == nil,
    data = data,
    error = failure,
  })
  run(steps_for(command))
end

run(script.on_start)

for line in io.lines() do
  local ok, command = pcall(vim.json.decode, line)
  if ok and type(command) == 'table' then
    handle(command)
  end
end
