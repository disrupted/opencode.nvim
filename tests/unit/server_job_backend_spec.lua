local assert = require('luassert')
local Promise = require('opencode.promise')
local registry = require('opencode.protocols.registry')

describe('server_job with a non-opencode backend', function()
  local config = require('opencode.config')
  local state = require('opencode.state')
  local server_job = require('opencode.server_job')
  local OpencodeServer = require('opencode.opencode_server')
  local original_backend

  before_each(function()
    original_backend = config.backend
    state.jobs.clear_server()
  end)

  after_each(function()
    config.values.backend = original_backend
    state.jobs.clear_server()
  end)

  it('delegates launch and health to the registered adapter without HTTP', function()
    local launches, health_checks = 0, 0
    local server = OpencodeServer.new()
    server.kind = 'stdio'
    server.protocol = 'fake_stdio'
    server.server_identity = { version = '1' }

    registry.register({
      name = 'fake_stdio',
      health_path = '',
      operations = 'opencode.protocols.v2.operations',
      observation = 'opencode.protocols.v2.observation',
      decode_probe = function() end,
      start_server = function()
        launches = launches + 1
        server:mark_ready()
        return Promise.new():resolve(server)
      end,
      check_health = function()
        health_checks = health_checks + 1
        return Promise.new():resolve(true)
      end,
    })
    package.loaded['opencode.protocols.fake_stdio.connection'] = true
    config.values.backend = 'fake_stdio'

    assert.equals(server, server_job.ensure_server():wait())
    assert.equals(1, launches)
    assert.equals(server, state.opencode_server)

    assert.equals(server, server_job.ensure_server({ force_health_check = true }):wait())
    assert.equals(1, launches)
    assert.equals(1, health_checks)
    server:close()
  end)
end)
