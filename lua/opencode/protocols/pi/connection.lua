local Promise = require('opencode.promise')
local OpencodeServer = require('opencode.opencode_server')
local process = require('opencode.protocols.pi.process')
local registry = require('opencode.protocols.registry')
local ui_requests = require('opencode.protocols.pi.ui_requests')

---@type OpencodeProtocolAdapter
local M = {
  name = 'pi',
  health_path = '',
  operations = 'opencode.protocols.pi.operations',
  observation = 'opencode.protocols.pi.observation',
  -- Never probed: there is no endpoint to ask.
  decode_probe = function() end,
}

---@return Promise<boolean>
function M.check_health()
  return Promise.new():resolve(process.get().process:is_running())
end

---@return Promise<OpencodeServer>
function M.start_server()
  return Promise.async(function()
    local client = process.get()
    client.process:start():await()
    local pi_state = client:get_state():await()

    ---@type OpencodePiConnection
    local connection = OpencodeServer.new() --[[@as OpencodePiConnection]]
    connection.kind = 'stdio'
    connection.protocol = 'pi'
    connection.server_identity = { version = 'pi' }
    connection.capabilities = { single_agent = true }
    connection.pi = { session_id = pi_state.sessionId }
    local unsubscribe = process.on_event(function(event)
      if event.type == 'extension_ui_request' then
        ui_requests.dispatch(connection, event)
      end
    end)
    connection:set_process_release(function()
      unsubscribe()
      client.process:stop()
    end)
    return connection:mark_ready()
  end)()
end

registry.register(M)

return M
