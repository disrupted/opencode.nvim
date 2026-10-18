local config = require('opencode.config')

local M = {}

---@return string[]
function M.command()
  local command = { config.pi.executable, '--mode', 'rpc' }
  vim.list_extend(command, config.pi.args)
  return command
end

---Mirrors pi's own resolution so history is read from where pi writes it.
---@return string
function M.session_root()
  local session_dir = vim.uv.os_getenv('PI_CODING_AGENT_SESSION_DIR')
  if session_dir and session_dir ~= '' then
    return vim.fs.normalize(vim.fn.expand(session_dir))
  end

  local agent_dir = vim.uv.os_getenv('PI_CODING_AGENT_DIR')
  if agent_dir and agent_dir ~= '' then
    return vim.fs.normalize(vim.fs.joinpath(vim.fn.expand(agent_dir), 'sessions'))
  end

  return vim.fs.normalize(vim.fs.joinpath(vim.uv.os_homedir(), '.pi', 'agent', 'sessions'))
end

return M
