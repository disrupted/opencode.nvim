local Promise = require('opencode.promise')

describe('open session smoke test (pi backend)', function()
  local saved_env
  local original_get
  local session_dir
  local rpc_client
  local state = require('opencode.state')

  local function write_fixture(path)
    local lines = {
      { type = 'session', id = 'smoke-session', cwd = vim.fn.getcwd(), timestamp = '2026-01-01T10:00:00Z' },
      {
        type = 'message',
        timestamp = '2026-01-01T10:00:01Z',
        message = { role = 'user', timestamp = 1000, content = { { type = 'text', text = 'list files' } } },
      },
      {
        type = 'message',
        timestamp = '2026-01-01T10:00:02Z',
        message = {
          role = 'assistant',
          timestamp = 2000,
          content = {
            { type = 'text', text = 'Running ls' },
            { type = 'toolCall', id = 'call_1', name = 'bash', arguments = { command = 'ls', description = 'list' } },
          },
        },
      },
      {
        type = 'message',
        timestamp = '2026-01-01T10:00:03Z',
        message = {
          role = 'toolResult',
          timestamp = 3000,
          toolCallId = 'call_1',
          toolName = 'bash',
          content = { { type = 'text', text = 'smoke_fixture_output.txt' } },
        },
      },
    }
    vim.fn.writefile(vim.tbl_map(vim.json.encode, lines), path)
  end

  local function fake_rpc(path)
    local handlers = {
      get_state = { sessionFile = path, sessionId = 'smoke-session' },
      switch_session = { cancelled = false },
      get_messages = {
        messages = vim
          .iter(vim.fn.readfile(path))
          :map(vim.json.decode)
          :filter(function(entry)
            return entry.type == 'message'
          end)
          :map(function(entry)
            return entry.message
          end)
          :totable(),
      },
    }
    local process = {
      start = function()
        return Promise.new():resolve(true)
      end,
      is_running = function()
        return true
      end,
      stop = function() end,
    }
    return setmetatable({ process = process }, {
      __index = function(_, name)
        return function()
          return Promise.new():resolve(handlers[name] or {})
        end
      end,
    })
  end

  before_each(function()
    -- The agent environment points PI_* and XDG_* at real data; nothing of it may leak in.
    saved_env = {}
    for name in pairs(vim.fn.environ()) do
      if name:match('^PI_') then
        saved_env[name] = vim.env[name]
        vim.env[name] = nil
      end
    end
    local root = vim.fn.tempname()
    for name, dir in pairs({ XDG_STATE_HOME = 'state', XDG_DATA_HOME = 'data', XDG_CONFIG_HOME = 'config' }) do
      saved_env[name] = saved_env[name] or vim.env[name] or false
      vim.env[name] = vim.fs.joinpath(root, dir)
    end
    session_dir = vim.fs.joinpath(root, 'sessions')
    vim.fn.mkdir(session_dir, 'p')
    vim.env.PI_CODING_AGENT_DIR = vim.fs.joinpath(root, 'agent')
    vim.env.PI_CODING_AGENT_SESSION_DIR = session_dir
    write_fixture(vim.fs.joinpath(session_dir, 'smoke.jsonl'))
  end)

  after_each(function()
    if rpc_client then
      rpc_client.get = original_get
      rpc_client = nil
    end
    vim.env.PI_CODING_AGENT_DIR = nil
    vim.env.PI_CODING_AGENT_SESSION_DIR = nil
    for name, value in pairs(saved_env) do
      vim.env[name] = value or nil
    end
    if state.windows then
      require('opencode.ui.ui').close_windows(state.windows, false)
    end
    vim.fn.delete(vim.fs.dirname(session_dir), 'rf')
  end)

  it('opens the UI, loads the latest session and renders its messages', function()
    local loaded, module = pcall(require, 'opencode.protocols.pi.process')
    assert(loaded, 'Pi protocol adapter missing: opencode.protocols.pi.process cannot be loaded\n' .. tostring(module))
    rpc_client = module
    original_get = rpc_client.get
    rpc_client.get = function()
      return fake_rpc(vim.fs.joinpath(session_dir, 'smoke.jsonl'))
    end

    require('opencode').setup({ backend = 'pi' })

    local rejection
    require('opencode.services.session_runtime')
      .open({ new_session = false, focus = 'input', start_insert = false })
      :catch(function(err)
        rejection = err
      end)

    local rendered = function()
      local buf = state.windows and state.windows.output_buf
      if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return false
      end
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find('smoke_fixture_output.txt', 1, true)
        ~= nil
    end
    vim.wait(5000, function()
      return rejection ~= nil or rendered()
    end, 20)

    assert.is_nil(rejection)
    assert.is_truthy(state.active_session)
    assert.is_true(rendered())
  end)
end)
