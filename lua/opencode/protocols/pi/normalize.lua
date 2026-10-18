local M = {}

local tool_aliases = {
  run = 'bash',
  ls = 'list',
  todo_write = 'todowrite',
}

---@param name any
---@return string
function M.tool_name(name)
  local lower = tostring(name or 'tool'):lower()
  return tool_aliases[lower] or lower
end

---@param role string
---@param message OpencodePiMessage
---@param index integer
---@return string
function M.message_id(role, message, index)
  -- responseId only appears once a message is complete, so live updates keep the id pinned at message start.
  if role == 'assistant' and type(message.responseId) == 'string' and message.responseId ~= '' then
    return ('pi_%s_%s'):format(role, message.responseId:gsub('[^%w_%-]', '_'))
  end
  local stamp = message.timestamp or ('i' .. index)
  return ('pi_%s_%s'):format(role, tostring(stamp):gsub('[^%w_%-]', '_'))
end

---@param content any
---@return string
local function text_of(content)
  if type(content) == 'string' then
    return content
  end
  local chunks = {}
  for _, item in ipairs(content or {}) do
    if item.type == 'text' then
      chunks[#chunks + 1] = item.text or ''
    elseif item.type == 'image' then
      chunks[#chunks + 1] = '[image]'
    end
  end
  return table.concat(chunks, '\n')
end

---@param output string
---@param is_error? boolean
---@return table
local function tool_outcome(output, is_error)
  return {
    state = is_error and 'error' or 'completed',
    result = { { kind = 'text', text = output } },
    error = is_error and { message = output } or nil,
  }
end

---@param part table
---@param outcome table
local function apply_outcome(part, outcome)
  part.state, part.result, part.error = outcome.state, outcome.result, outcome.error
end

---Result is merged into the call that produced it, whether it arrives with history or live.
---@param part table
---@param message {content?: any, isError?: boolean, timestamp?: number}
function M.apply_tool_result(part, message)
  apply_outcome(part, tool_outcome(text_of(message.content), message.isError))
  part.time = part.time or {}
  part.time.completed = message.timestamp
end

---@param part table
---@param event table `tool_execution_*` event
function M.apply_tool_execution(part, event)
  local result = event.result or event.partialResult or {}
  local finished = event.type == 'tool_execution_end'
  local failed = result.isError or event.isError or false
  part.time = part.time or {}
  if finished then
    apply_outcome(part, tool_outcome(text_of(result.content), failed))
    part.time.completed = vim.uv.now()
  else
    part.state = 'running'
    part.time.started = part.time.started or vim.uv.now()
    if event.partialResult then
      part.result = { { kind = 'text', text = text_of(result.content) } }
    end
  end
end

---@param item table
---@return table
local function tool_part(item)
  local input = item.arguments or {}
  local part = {
    kind = 'tool',
    call_id = item.id or item.callID,
    name = M.tool_name(item.name),
    state = 'pending',
    input = input,
    time = {},
  }
  if part.name == 'bash' then
    part.command, part.description = input.command, input.description
  end
  local path = input.path or input.file_path
  if (part.name == 'read' or part.name == 'edit' or part.name == 'write') and type(path) == 'string' then
    part.target = { path = path, content = part.name == 'write' and input.content or nil }
  end
  return part
end

---@param usage table|nil
---@return table|nil
local function tokens(usage)
  if not usage then
    return nil
  end
  return {
    input = usage.input,
    output = usage.output,
    cache = { read = usage.cacheRead, write = usage.cacheWrite },
  }
end

---@param message OpencodePiMessage
---@param entry table
local function assistant_content(message, entry)
  local items = type(message.content) == 'table' and message.content or {}
  if #items == 0 and (message.stopReason == 'error' or message.stopReason == 'aborted') then
    entry.content[1] = { kind = 'text', text = 'Pi stopped: ' .. tostring(message.errorMessage or message.stopReason) }
  end
  if type(message.content) == 'string' and message.content ~= '' then
    entry.content[#entry.content + 1] = { kind = 'text', text = message.content }
  end
  for _, item in ipairs(items) do
    if item.type == 'thinking' then
      entry.content[#entry.content + 1] = { kind = 'reasoning', text = item.thinking or '' }
    elseif item.type == 'toolCall' then
      entry.content[#entry.content + 1] = tool_part(item)
    elseif item.type == 'text' then
      entry.content[#entry.content + 1] = { kind = 'text', text = item.text or '' }
    end
  end
end

---@param entry table
function M.assign_content_ids(entry)
  local ordinals = {}
  for _, content in ipairs(entry.content) do
    local key = content.kind == 'tool' and content.call_id or (ordinals[content.kind] or 0)
    ordinals[content.kind] = (ordinals[content.kind] or 0) + 1
    content.id = ('%s:%s:%s'):format(entry.id, content.kind, tostring(key))
  end
end

---A toolResult without a matching call still has to be visible.
---@param message OpencodePiMessage
---@return table
local function orphan_tool_part(message)
  local part = tool_part({ id = message.toolCallId, name = message.toolName })
  M.apply_tool_result(part, message)
  return part
end

---@param message OpencodePiMessage
---@param session_id string
---@param index integer
---@param id? string Pins the identity of a message whose snapshots arrive without a stable key
---@return table|nil entry nil for roles the UI has no entry for
function M.entry(message, session_id, index, id)
  local role = message.role == 'toolResult' and 'assistant' or message.role
  if role ~= 'user' and role ~= 'assistant' then
    return nil
  end
  local entry = {
    id = id or M.message_id(message.role, message, index),
    session_id = session_id,
    kind = role,
    time = { created = type(message.timestamp) == 'number' and message.timestamp or nil },
    content = {},
  }
  if message.role == 'user' then
    entry.content[1] = { kind = 'text', text = text_of(message.content) }
  elseif message.role == 'toolResult' then
    entry.content[1] = orphan_tool_part(message)
  else
    entry.agent = 'pi'
    entry.finish = message.stopReason
    entry.cost = message.usage and message.usage.cost and message.usage.cost.total or nil
    entry.tokens = tokens(message.usage)
    if message.provider and message.model then
      entry.model = { providerID = message.provider, modelID = message.model }
    end
    assistant_content(message, entry)
  end
  M.assign_content_ids(entry)
  return entry
end

---@param entries table[]
---@return table<string, table?> tool parts by call id
local function index_tool_parts(entries)
  local parts = {}
  for _, entry in ipairs(entries) do
    for _, content in ipairs(entry.content) do
      if content.kind == 'tool' and content.call_id then
        parts[content.call_id] = content
      end
    end
  end
  return parts
end

---Entries in chronological order, with each toolResult folded into its tool call.
---@param messages OpencodePiMessage[]
---@param session_id string
---@return table[]
function M.entries(messages, session_id)
  local entries = {}
  ---@type table<string, table>
  local calls = {}
  for index, message in ipairs(messages) do
    local call = message.role == 'toolResult' and calls[
      message.toolCallId --[[@as string]]
    ]
    if call then
      M.apply_tool_result(call, message)
    else
      local entry = M.entry(message, session_id, index)
      if entry then
        entries[#entries + 1] = entry
        for call_id, part in pairs(index_tool_parts({ entry })) do
          calls[call_id] = part
        end
      end
    end
  end
  return entries
end

---Rebuilding an assistant entry from a streamed snapshot must not discard results already merged into it.
---@param entry table
---@param previous? table
function M.carry_tool_state(entry, previous)
  if not previous then
    return
  end
  local old = index_tool_parts({ previous })
  for _, content in ipairs(entry.content) do
    local before = content.kind == 'tool' and old[content.call_id]
    if before and before.result then
      content.state, content.result, content.error, content.time =
        before.state, before.result, before.error, before.time
    elseif before then
      content.state, content.time = before.state, before.time
    end
  end
end

M.index_tool_parts = index_tool_parts

return M
