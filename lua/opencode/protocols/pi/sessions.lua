local server = require('opencode.protocols.pi.server')

local M = {}

---@param content any
---@return string
local function content_text(content)
  if type(content) == 'string' then
    return content
  end
  local chunks = {}
  for _, item in ipairs(content or {}) do
    if item.type == 'text' then
      chunks[#chunks + 1] = item.text or ''
    end
  end
  return table.concat(chunks, ' ')
end

---@param text string
---@param max_len integer
---@return string|nil
local function truncate(text, max_len)
  text = vim.trim(text:gsub('%s+', ' '))
  if text == '' then
    return nil
  end
  if vim.fn.strchars(text) <= max_len then
    return text
  end
  return vim.fn.strcharpart(text, 0, max_len - 1) .. '…'
end

---@param path string
---@return table[] entries Decodable JSONL records; broken lines are skipped like pi does
local function read_entries(path)
  local entries = {}
  for _, line in ipairs(vim.fn.readfile(path)) do
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == 'table' then
      entries[#entries + 1] = entry
    end
  end
  return entries
end

---@param path string
---@return OpencodePiSessionFact|nil
local function read_session(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then
    return nil
  end

  local header, name, first_user
  for _, entry in ipairs(read_entries(path)) do
    if not header and entry.type == 'session' then
      header = entry
    elseif entry.type == 'session_info' then
      name = truncate(entry.name or '', 70)
    elseif entry.type == 'message' and not first_user and type(entry.message) == 'table' then
      if entry.message.role == 'user' then
        first_user = truncate(content_text(entry.message.content), 70)
      end
    end
  end
  if not header then
    return nil
  end

  local updated = stat.mtime.sec * 1000
  local created = (stat.birthtime and stat.birthtime.sec or stat.ctime.sec) * 1000
  return {
    id = header.id,
    title = name or header.name or first_user or header.id,
    location = { directory = header.cwd },
    time = { created = created, updated = updated },
    path = path,
  }
end

---Newest first; one fact per session id, because a forked file repeats its parent's header id.
---@return OpencodePiSessionFact[]
function M.list()
  local root = server.session_root()
  if vim.fn.isdirectory(root) == 0 then
    return {}
  end

  local by_id = {}
  for _, path in ipairs(vim.fn.glob(vim.fs.joinpath(root, '**', '*.jsonl'), false, true)) do
    local session = read_session(vim.fs.normalize(path))
    local existing = session and by_id[session.id]
    if session and (not existing or session.time.updated > existing.time.updated) then
      by_id[session.id] = session
    end
  end

  local sessions = vim.tbl_values(by_id)
  table.sort(sessions, function(a, b)
    return a.time.updated > b.time.updated
  end)
  return sessions
end

---@param id string
---@return OpencodePiSessionFact|nil
function M.find(id)
  for _, session in ipairs(M.list()) do
    if session.id == id then
      return session
    end
  end
end

---@param path string
---@return OpencodePiMessage[]
function M.read_messages(path)
  local messages = {}
  for _, entry in ipairs(read_entries(path)) do
    if entry.type == 'message' and type(entry.message) == 'table' then
      local message = vim.deepcopy(entry.message)
      message.timestamp = message.timestamp or entry.timestamp
      messages[#messages + 1] = message
    end
  end
  return messages
end

return M
