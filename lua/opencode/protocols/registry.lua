local M = {}

---@type table<string, OpencodeProtocolAdapter>
local adapters = {}

---@param adapter OpencodeProtocolAdapter
function M.register(adapter)
  if adapters[adapter.name] and adapters[adapter.name] ~= adapter then
    error('protocol adapter already registered: ' .. adapter.name)
  end
  adapters[adapter.name] = adapter
end

---@param name string
---@return OpencodeProtocolAdapter|nil
function M.get(name)
  return adapters[name]
end

---Adapters that take part in HTTP probing, lowest `probe_rank` first.
---@return OpencodeProtocolAdapter[]
function M.probe_order()
  local ordered = {}
  for _, adapter in pairs(adapters) do
    if adapter.probe_rank then
      ordered[#ordered + 1] = adapter
    end
  end
  table.sort(ordered, function(a, b)
    return a.probe_rank < b.probe_rank
  end)
  return ordered
end

return M
