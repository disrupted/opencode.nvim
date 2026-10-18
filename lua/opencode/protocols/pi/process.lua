local Promise = require('opencode.promise')
local server = require('opencode.protocols.pi.server')
local log = require('opencode.log')

local M = {}

---@type fun(event: table)[]
local listeners = {}

---Events live outside the client so a replaced client (see `M.get`) cannot orphan subscribers.
---@param callback fun(event: table)
---@return fun() unsubscribe
function M.on_event(callback)
  listeners[#listeners + 1] = callback
  return function()
    for i = #listeners, 1, -1 do
      if listeners[i] == callback then
        table.remove(listeners, i)
      end
    end
  end
end

---@param event table
local function emit(event)
  for _, callback in ipairs(vim.list_slice(listeners)) do
    local ok, err = pcall(callback, event)
    if not ok then
      log.warn('pi event listener failed: %s', tostring(err))
    end
  end
end

---@class OpencodePiProcess
---@field job_id? integer
---@field exited boolean
---@field stopping boolean
---@field crashed boolean Exited without being asked to; requests fail until `restart` so a dead pi is never revived silently
---@field stdout_buffer string
---@field generation integer Distinguishes a restarted job from the stopped one whose callbacks may still arrive
---@field on_line fun(line: string)
---@field on_exit fun()
local Process = {}
Process.__index = Process

---@param on_line fun(line: string)
---@param on_exit fun()
---@return OpencodePiProcess
function Process.new(on_line, on_exit)
  return setmetatable({
    exited = false,
    stopping = false,
    crashed = false,
    stdout_buffer = '',
    generation = 0,
    on_line = on_line,
    on_exit = on_exit,
  }, Process)
end

---@return boolean
function Process:is_running()
  return self.job_id ~= nil and not self.exited
end

---@param data string[] jobstart splits on LF; rejoin so records are not cut mid-line
function Process:_feed(data)
  for i, chunk in ipairs(data) do
    if i == 1 then
      self.stdout_buffer = self.stdout_buffer .. chunk
    else
      self.on_line(self.stdout_buffer)
      self.stdout_buffer = chunk
    end
  end
end

---@return Promise<OpencodePiProcess>
function Process:start()
  if self:is_running() then
    return Promise.new():resolve(self)
  end
  local command = server.command()
  local executable = command[1] --[[@as string]]
  if vim.fn.executable(executable) == 0 then
    return Promise.new():reject(executable .. ' command not found')
  end

  self.exited, self.stopping, self.crashed, self.stdout_buffer = false, false, false, ''
  self.generation = self.generation + 1
  local generation = self.generation
  local job_id = vim.fn.jobstart(command, {
    cwd = vim.fn.getcwd(),
    stdin = 'pipe',
    on_stdout = function(_, data)
      vim.schedule(function()
        if generation == self.generation then
          self:_feed(data)
        end
      end)
    end,
    on_stderr = function(_, data)
      local text = table.concat(data, '\n')
      if text ~= '' then
        log.warn('pi stderr: %s', text)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if generation ~= self.generation then
          emit({ type = 'process_exit', code = code, expected = true })
          return
        end
        local expected = self.stopping
        self.exited, self.job_id = true, nil
        self.crashed = not expected
        self.on_exit()
        emit({ type = 'process_exit', code = code, expected = expected })
      end)
    end,
  })
  if job_id <= 0 then
    return Promise.new():reject('failed to start pi RPC process')
  end
  self.job_id = job_id
  return Promise.new():resolve(self)
end

---@return Promise<OpencodePiProcess>
function Process:restart()
  self.crashed = false
  return self:start()
end

---@param command table
---@return Promise<boolean>
function Process:send(command)
  if self.crashed then
    return Promise.new():reject('pi process exited unexpectedly; restart it to continue')
  end
  return self:start():and_then(function()
    local ok = pcall(vim.fn.chansend, self.job_id --[[@as integer]], vim.json.encode(command) .. '\n')
    if not ok then
      error('failed to write to pi RPC process', 0)
    end
    return true
  end)
end

function Process:stop()
  self.exited, self.crashed = true, false
  if self.job_id then
    self.stopping = true
    pcall(vim.fn.chanclose, self.job_id, 'stdin')
    pcall(vim.fn.jobstop, self.job_id)
    self.job_id = nil
    self.on_exit()
  end
end

---@class OpencodePiRpcClient: OpencodePiClient
---@field process OpencodePiProcess
---@field pending table<string, Promise<any>?>
---@field streaming boolean
local Client = {}
Client.__index = Client

local request_counter = 0

---@return OpencodePiRpcClient
function Client.new()
  local self = setmetatable({ pending = {}, streaming = false }, Client)
  self.process = Process.new(function(line)
    self:_handle_line(line)
  end, function()
    local pending = self.pending
    self.pending, self.streaming = {}, false
    for _, promise in pairs(pending) do
      promise:reject('pi RPC process exited')
    end
  end)
  return self
end

---@param line string
function Client:_handle_line(line)
  line = line:gsub('\r$', '')
  if line == '' then
    return
  end
  local ok, event = pcall(vim.json.decode, line)
  if not ok or type(event) ~= 'table' then
    log.warn('undecodable pi RPC line: %s', line)
    return
  end
  local pending = event.type == 'response' and event.id and self.pending[event.id]
  if pending then
    self.pending[event.id] = nil
    if event.success == false then
      pending:reject(event.error or event)
    else
      pending:resolve(event.data ~= nil and event.data or event)
    end
    return
  end
  if event.type == 'agent_start' then
    self.streaming = true
  elseif event.type == 'agent_settled' then
    self.streaming = false
  end
  emit(event)
end

---@param command table
---@return Promise<any>
function Client:request(command)
  request_counter = request_counter + 1
  local id = 'nvim-' .. request_counter
  command.id = id
  local promise = Promise.new()
  self.pending[id] = promise
  self.process:send(command):catch(function(err)
    self.pending[id] = nil
    promise:reject(err)
  end)
  return promise
end

function Client:get_state()
  return self:request({ type = 'get_state' })
end

function Client:get_messages()
  return self:request({ type = 'get_messages' })
end

function Client:switch_session(path)
  return self:request({ type = 'switch_session', sessionPath = path })
end

function Client:new_session()
  return self:request({ type = 'new_session' })
end

---@param message string
---@param behavior? 'steer'|'followUp'|false How to queue during a run; false sends it as a plain prompt, nil follows the observed run state
function Client:prompt(message, behavior)
  if behavior == nil and self.streaming then
    behavior = 'steer'
  end
  -- pi rejects a prompt during a run unless it says how to queue it.
  return self:request({ type = 'prompt', message = message, streamingBehavior = behavior or nil })
end

---Answers a dialog; pi sends no response to it, so nothing is awaited.
---@param reply {id: string, value?: string, confirmed?: boolean, cancelled?: boolean}
---@return Promise<boolean>
function Client:extension_ui_response(reply)
  return self.process:send(vim.tbl_extend('force', { type = 'extension_ui_response' }, reply))
end

function Client:abort()
  return self:request({ type = 'abort' })
end

function Client:get_available_models()
  return self:request({ type = 'get_available_models' })
end

function Client:set_model(provider, model_id)
  return self:request({ type = 'set_model', provider = provider, modelId = model_id })
end

function Client:cycle_model()
  return self:request({ type = 'cycle_model' })
end

function Client:set_thinking_level(level)
  return self:request({ type = 'set_thinking_level', level = level })
end

function Client:cycle_thinking_level()
  return self:request({ type = 'cycle_thinking_level' })
end

function Client:get_commands()
  return self:request({ type = 'get_commands' })
end

function Client:set_session_name(name)
  return self:request({ type = 'set_session_name', name = name })
end

function Client:compact()
  return self:request({ type = 'compact' })
end

function Client:get_fork_messages()
  return self:request({ type = 'get_fork_messages' })
end

function Client:fork(entry_id)
  return self:request({ type = 'fork', entryId = entry_id })
end

function Client:clone()
  return self:request({ type = 'clone' })
end

---@type OpencodePiClient|nil
local instance

---Single client per Neovim instance; tests replace this function to inject a fake.
---@return OpencodePiClient
function M.get()
  instance = instance or Client.new()
  return instance
end

return M
