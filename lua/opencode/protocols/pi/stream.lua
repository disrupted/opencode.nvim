local M = {}

---Pi's wire `message_update` is delta-only, so the live message is rebuilt locally.
---@param message OpencodePiMessage Live assistant snapshot, mutated in place
---@param update {type: string, contentIndex?: integer, delta?: string, content?: string, id?: string, toolName?: string, toolCall?: table}
---@return boolean changed
function M.apply(message, update)
  local content = message.content --[[@as table[] ]]
  local index = (update.contentIndex or 0) + 1
  local kind = update.type
  if kind == 'text_start' then
    content[index] = { type = 'text', text = '' }
  elseif kind == 'thinking_start' then
    content[index] = { type = 'thinking', thinking = '' }
  elseif kind == 'toolcall_start' then
    content[index] = { type = 'toolCall', id = update.id, name = update.toolName, arguments = {} }
  elseif kind == 'text_delta' and content[index] then
    content[index].text = content[index].text .. update.delta
  elseif kind == 'thinking_delta' and content[index] then
    content[index].thinking = content[index].thinking .. update.delta
  elseif kind == 'text_end' and content[index] then
    content[index].text = update.content
  elseif kind == 'thinking_end' and content[index] then
    content[index].thinking = update.content
  elseif kind == 'toolcall_end' then
    content[index] = update.toolCall
  else
    return false
  end
  return true
end

return M
