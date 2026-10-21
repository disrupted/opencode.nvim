local config = require('opencode.config')

---Runs the scripted `tests/mocks/fake_pi` as the pi executable, with every pi/XDG path pointed at a temp dir.
local M = {}

---@class FakePiContext
---@field root string
---@field session_dir string
---@field log_path string
---@field executable string
---@field saved_env table<string, string|false>
---@field saved_pi table
local Context = {}
Context.__index = Context

---@param script table See tests/mocks/fake_pi.lua
---@return FakePiContext
function M.start(script)
  ---@type table<string, string|false>
  local saved_env = {}
  for name in pairs(vim.fn.environ()) do
    if name:match('^PI_') or name:match('^FAKE_PI_') then
      saved_env[name] = vim.env[name]
      vim.env[name] = nil
    end
  end

  local root = vim.fn.tempname()
  local session_dir = vim.fs.joinpath(root, 'sessions')
  vim.fn.mkdir(session_dir, 'p')
  for name, dir in pairs({ XDG_STATE_HOME = 'state', XDG_DATA_HOME = 'data', XDG_CONFIG_HOME = 'config' }) do
    saved_env[name] = saved_env[name] or vim.env[name] or false
    vim.env[name] = vim.fs.joinpath(root, dir)
  end
  saved_env.PI_CODING_AGENT_DIR = false
  saved_env.PI_CODING_AGENT_SESSION_DIR = false
  vim.env.PI_CODING_AGENT_DIR = vim.fs.joinpath(root, 'agent')
  vim.env.PI_CODING_AGENT_SESSION_DIR = session_dir

  local script_path = vim.fs.joinpath(root, 'script.json')
  local log_path = vim.fs.joinpath(root, 'commands.jsonl')
  vim.fn.writefile({ vim.json.encode(script) }, script_path)
  vim.env.FAKE_PI_SCRIPT = script_path
  vim.env.FAKE_PI_LOG = log_path
  vim.env.FAKE_PI_NVIM = vim.v.progpath
  saved_env.FAKE_PI_SCRIPT, saved_env.FAKE_PI_LOG, saved_env.FAKE_PI_NVIM = false, false, false

  local executable = vim.fs.joinpath(assert(vim.uv.cwd()), 'tests', 'mocks', 'fake_pi')
  local saved_pi = vim.deepcopy(config.values.pi)
  config.values.pi = { executable = executable, args = {} }

  return setmetatable({
    root = root,
    session_dir = session_dir,
    log_path = log_path,
    executable = executable,
    saved_env = saved_env,
    saved_pi = saved_pi,
  }, Context)
end

---@param name string
---@param header table
---@param messages? table[]
---@return string path
function Context:write_session(name, header, messages)
  local path = vim.fs.joinpath(self.session_dir, name)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local lines = { vim.json.encode(vim.tbl_extend('keep', header, { type = 'session' })) }
  for _, message in ipairs(messages or {}) do
    lines[#lines + 1] = vim.json.encode({ type = 'message', message = message })
  end
  vim.fn.writefile(lines, path)
  return path
end

---Commands the fake received; the first record holds its argv.
---@return table[]
function Context:received()
  if vim.fn.filereadable(self.log_path) == 0 then
    return {}
  end
  return vim.tbl_map(vim.json.decode, vim.fn.readfile(self.log_path))
end

---@param command_type string
---@return table[]
function Context:received_of(command_type)
  return vim.tbl_filter(function(record)
    return record.type == command_type
  end, self:received())
end

function Context:stop()
  local process = require('opencode.protocols.pi.process')
  local running = process.get().process:is_running()
  local exited = false
  local off = process.on_event(function(event)
    exited = exited or event.type == 'process_exit'
  end)
  process.get().process:stop()
  -- A late exit event would otherwise leak into the next test's listeners.
  if running then
    vim.wait(2000, function()
      return exited
    end, 10)
  end
  off()
  config.values.pi = self.saved_pi
  for name, value in pairs(self.saved_env) do
    vim.env[name] = value or nil
  end
  vim.fn.delete(self.root, 'rf')
end

return M
