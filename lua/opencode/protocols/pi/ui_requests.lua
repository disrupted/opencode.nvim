local log = require('opencode.log')
local process = require('opencode.protocols.pi.process')

local M = {}

---@class OpencodePiUiRequest
---@field kind 'permission'|'question'
---@field method string

---@type table<string, 'permission'|'question'>
local dialog_kinds = {
  confirm = 'permission',
  select = 'question',
  input = 'question',
  editor = 'question',
}

---@param method string
---@return 'permission'|'question'|nil
function M.dialog_kind(method)
  return dialog_kinds[method]
end

---@param notify_type? string
---@return integer
function M.level(notify_type)
  if notify_type == 'error' then
    return vim.log.levels.ERROR
  elseif notify_type == 'warning' then
    return vim.log.levels.WARN
  end
  return vim.log.levels.INFO
end

---@class OpencodePiPermissionRequest
---@field id string
---@field session_id string
---@field action string
---@field resources string[]
---@field status string
---@field message? string
---@field preview {title?: string}
---@field choices {value: string, label: string, description: string}[]

---@class OpencodePiQuestionRequest
---@field id string
---@field session_id string
---@field status string
---@field title? string
---@field fields OpencodeQuestionInfo[]

---@param event table `extension_ui_request` with method `confirm`
---@param session_id string
---@return OpencodePiPermissionRequest
function M.permission(event, session_id)
  return {
    id = event.id,
    session_id = session_id,
    action = 'confirm',
    resources = {},
    status = 'pending',
    message = event.message,
    preview = { title = event.title },
    choices = {
      { value = 'once', label = 'Yes', description = 'Confirm' },
      { value = 'reject', label = 'No', description = 'Decline' },
    },
  }
end

---Pi dialogs carry one value, so each becomes a single-field question.
---@param event table `extension_ui_request` with method `select`, `input` or `editor`
---@param session_id string
---@return OpencodePiQuestionRequest
function M.question(event, session_id)
  local options = {}
  local choices = event.method == 'select' and event.options or {}
  if event.method == 'editor' and type(event.prefill) == 'string' and event.prefill ~= '' then
    choices = { event.prefill }
  end
  for _, choice in ipairs(choices) do
    options[#options + 1] = { value = choice, label = choice, description = '' }
  end
  local prompt = event.title or event.placeholder or 'Pi'
  return {
    id = event.id,
    session_id = session_id,
    status = 'pending',
    title = event.title,
    fields = {
      {
        key = 'value',
        type = 'string',
        prompt = prompt,
        title = event.title,
        required = true,
        options = options,
        custom = event.method ~= 'select',
      },
    },
  }
end

local noticed_methods = {}

---Footer and widget decorations carry nothing the user must act on, so they do not deserve a notice per extension.
local decoration_methods = { 'setStatus', 'setWidget', 'setTitle' }

---Handles what needs no observation, so it works while no UI is open and no event stream runs.
---@param connection OpencodePiConnection
---@param event table `extension_ui_request`
function M.dispatch(connection, event)
  local method = event.method
  if method == 'notify' then
    log.notify(event.message or '', M.level(event.notifyType))
  elseif M.dialog_kind(method) then
    local observed = connection.observations[
      connection.pi.session_id --[[@as string]]
    ]
    ---@diagnostic disable-next-line: unnecessary-if
    if not observed then
      -- Pi blocks the extension until answered, so a dialog nobody can see is declined.
      log.warn('declining Pi extension dialog %s: no session is observed', tostring(event.id))
      process.get():extension_ui_response({ id = event.id, cancelled = true })
    end
  elseif vim.tbl_contains(decoration_methods, method) then
    log.debug('ignoring Pi extension UI decoration %s', method)
  elseif not noticed_methods[method] then
    noticed_methods[method] = true
    log.notify(
      ('Pi extension UI method %q is not supported by this client'):format(tostring(method)),
      vim.log.levels.INFO
    )
  end
end

return M
