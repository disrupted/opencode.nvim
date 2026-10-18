local M = {}

---Pi only reports levels for its current model, so other models expose `reasoning` without a variant list.
---@param model OpencodePiModel
---@param levels? string[] Supported levels when `model` is the current one
---@return table<string, table>|nil
local function variants_for(model, levels)
  if not (model.reasoning and levels and #levels > 1) then
    return nil
  end
  local variants = {}
  for _, level in ipairs(levels) do
    variants[level] = {}
  end
  return variants
end

---@param model OpencodePiModel
---@param current? OpencodePiModel
---@param levels? string[]
---@return table
local function catalog_model(model, current, levels)
  local is_current = current ~= nil and current.provider == model.provider and current.id == model.id
  return {
    id = model.id,
    name = model.name or model.id,
    providerID = model.provider,
    reasoning = model.reasoning == true,
    limit = { context = model.contextWindow or 0, output = model.maxTokens or 0 },
    variants = is_current and variants_for(model, levels) or nil,
  }
end

---@param models OpencodePiModel[]
---@param current? OpencodePiModel
---@param levels? string[] Levels supported by `current`
---@return table[] models Flat list in the shape of v2 `list_models`
function M.models(models, current, levels)
  return vim.tbl_map(function(model)
    return catalog_model(model, current, levels)
  end, models)
end

---@param models OpencodePiModel[]
---@return table[] providers Sorted by id so pickers do not reshuffle between requests
function M.providers(models)
  local seen, providers = {}, {}
  for _, model in ipairs(models) do
    if not seen[model.provider] then
      seen[model.provider] = true
      providers[#providers + 1] = { id = model.provider, name = model.provider }
    end
  end
  table.sort(providers, function(a, b)
    return a.id < b.id
  end)
  return providers
end

---@param models OpencodePiModel[]
---@param current? OpencodePiModel
---@param levels? string[] Levels supported by `current`
---@return {providers: table[], default: table<string, string>}
function M.catalog(models, current, levels)
  local providers = M.providers(models)
  local by_id = {}
  for _, provider in ipairs(providers) do
    provider.models = {}
    by_id[provider.id] = provider
  end
  for _, model in ipairs(models) do
    by_id[model.provider].models[model.id] = catalog_model(model, current, levels)
  end
  local default = {}
  if current then
    default[current.provider] = current.id
  end
  return { providers = providers, default = default }
end

---@param pi_state OpencodePiState
---@return OpencodeV2ModelReference|nil
function M.current_model(pi_state)
  local model = pi_state.model
  if not model then
    return nil
  end
  return { providerID = model.provider, id = model.id, variant = pi_state.thinkingLevel }
end

local SKILL_PREFIX = '^skill:'

---@param commands OpencodePiCommand[]
---@return table[]
function M.commands(commands)
  return vim.tbl_map(function(command)
    return {
      name = command.name,
      description = command.description,
      source = command.source,
      path = command.path,
    }
  end, commands)
end

---@param commands OpencodePiCommand[]
---@return table[]
function M.skills(commands)
  local skills = {}
  for _, command in ipairs(commands) do
    if command.source == 'skill' then
      skills[#skills + 1] = {
        id = command.name,
        name = (command.name:gsub(SKILL_PREFIX, '')),
        description = command.description,
        location = command.path or '',
        -- Pi expands `/skill:<name>` itself, so the message text is the invocation.
        content = '/' .. command.name,
      }
    end
  end
  return skills
end

---Skills have their own completion source; keeping them out avoids duplicate slash entries.
---@param commands OpencodePiCommand[]
---@return table<string, table>
function M.user_commands(commands)
  local result = {}
  for _, command in ipairs(commands) do
    if command.source ~= 'skill' then
      result[command.name] = { description = command.description or '', source = command.source, template = '' }
    end
  end
  return result
end

return M
