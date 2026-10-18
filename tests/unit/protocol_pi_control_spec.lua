local fake_pi = require('tests.mocks.fake_pi_support')
local process = require('opencode.protocols.pi.process')
local adapter = require('opencode.protocols.pi.connection')

describe('pi control surface over a fake pi process', function()
  local ctx, connection, observation, unwatch

  local sonnet = { id = 'sonnet', name = 'Sonnet', provider = 'anthropic', reasoning = true, contextWindow = 1000 }
  local gpt = { id = 'gpt', name = 'GPT', provider = 'openai', reasoning = false }

  local function wait_for(predicate, message)
    assert.is_true(vim.wait(5000, predicate, 10), message or 'timed out waiting for condition')
  end

  local function ev(event)
    return { event = event }
  end

  local function user(timestamp, text)
    return { role = 'user', timestamp = timestamp, content = { { type = 'text', text = text } } }
  end

  local function open(script)
    ctx = fake_pi.start(script)
    local session_id = (script.state and script.state.sessionId) or 'fake-session'
    connection = adapter.start_server():wait()
    observation = connection:observe({ id = session_id, location = { directory = vim.fn.getcwd() } })
    unwatch = observation:watch({ 'session', 'messages', 'execution' }, function() end)
    wait_for(function()
      local sync = observation:read().sync
      return sync.messages.state == 'current' and sync.session.state == 'current' and sync.execution.state == 'current'
    end, 'observation never became current')
  end

  local function ops()
    return connection.operations
  end

  local function location()
    return { directory = vim.fn.getcwd() }
  end

  local function types_received()
    return vim.tbl_map(
      function(record)
        return record.type
      end,
      vim.tbl_filter(function(record)
        return record.type ~= nil
      end, ctx:received())
    )
  end

  local function entries()
    local state = observation:read()
    return vim.tbl_map(function(id)
      return state.entries_by_id[id]
    end, state.entry_order)
  end

  local function last_text()
    local list = entries()
    return list[#list].content[1].text
  end

  local function fails(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
  end

  after_each(function()
    if unwatch then
      unwatch()
    end
    if connection then
      connection:close()
    end
    unwatch, connection, observation = nil, nil, nil
    ctx:stop()
  end)

  describe('models and thinking level', function()
    it('serves the catalog, providers, models and default from get_available_models and get_state', function()
      open({ models = { sonnet, gpt }, state = { sessionId = 's', model = sonnet, thinkingLevel = 'high' } })
      local result = ops().get_model_catalog(connection, location()):wait()
      assert.equals('Sonnet', result.providers[1].models.sonnet.name)
      assert.same({ anthropic = 'sonnet' }, result.default)

      local providers = ops().list_providers(connection, location()):wait()
      assert.equals(2, #providers.data)
      assert.same(location(), providers.location)
      assert.equals(2, #ops().list_models(connection, location()):wait())

      assert.same(
        { providerID = 'anthropic', id = 'sonnet', variant = 'high' },
        ops().get_default_model(connection, location()):wait()
      )
      assert.equals('anthropic/sonnet', ops().get_config(connection, location()):wait().model)
    end)

    it('reports no default model when pi has none selected', function()
      open({ models = { gpt } })
      assert.is_nil(ops().get_default_model(connection, location()):wait())
      assert.is_nil(ops().get_config(connection, location()):wait().model)
    end)

    it('sets the model and thinking level of a session', function()
      open({ models = { sonnet, gpt }, state = { sessionId = 's', model = gpt } })
      assert.is_true(
        ops().set_session_model(connection, 's', { providerID = 'anthropic', id = 'sonnet', variant = 'low' }):wait()
      )
      local set = ctx:received_of('set_model')[1]
      assert.equals('anthropic', set.provider)
      assert.equals('sonnet', set.modelId)
      assert.equals('low', ctx:received_of('set_thinking_level')[1].level)
    end)

    it('skips set_model and set_thinking_level that would change nothing', function()
      open({ models = { sonnet }, state = { sessionId = 's', model = sonnet, thinkingLevel = 'low' } })
      ops().set_session_model(connection, 's', { providerID = 'anthropic', id = 'sonnet', variant = 'low' }):wait()
      assert.equals(0, #ctx:received_of('set_model'))
      assert.equals(0, #ctx:received_of('set_thinking_level'))
    end)

    it('rejects an unknown model', function()
      open({ models = { gpt } })
      local err = fails(function()
        ops().set_session_model(connection, 'fake-session', { providerID = 'x', id = 'y' }):wait()
      end)
      assert.matches('unknown model', err)
    end)

    it('applies the selected model and variant before the prompt', function()
      open({ models = { sonnet, gpt }, state = { sessionId = 's', model = gpt } })
      observation
        :submit({
          text = 'go',
          model = { providerID = 'anthropic', modelID = 'sonnet' },
          variant = 'medium',
        })
        :wait()
      assert.same({ 'get_state', 'get_state', 'set_model', 'set_thinking_level', 'prompt' }, {
        unpack(types_received(), #types_received() - 4),
      })
    end)

    it('sets and cycles the thinking level', function()
      open({ models = { sonnet }, state = { sessionId = 's', model = sonnet, thinkingLevel = 'off' } })
      assert.equals('high', ops().set_thinking_level(connection, 'high'):wait())
      assert.equals('high', ctx:received_of('set_thinking_level')[1].level)
      assert.equals('xhigh', ops().cycle_thinking_level(connection):wait())
    end)

    it('says so when the model has no thinking levels to cycle', function()
      open({ models = { gpt }, state = { sessionId = 's', model = gpt } })
      assert.matches(
        'does not support',
        fails(function()
          ops().cycle_thinking_level(connection):wait()
        end)
      )
    end)

    it('cycles models and says so when there is nothing to cycle to', function()
      open({ models = { sonnet, gpt }, state = { sessionId = 's', model = sonnet, thinkingLevel = 'low' } })
      assert.same({ providerID = 'openai', id = 'gpt', variant = 'low' }, ops().cycle_model(connection):wait())
      ctx:stop()
      open({ models = { gpt } })
      assert.matches(
        'No other model',
        fails(function()
          ops().cycle_model(connection):wait()
        end)
      )
    end)
  end)

  describe('commands and skills', function()
    local commands = {
      { name = 'review', description = 'Review code', source = 'prompt', path = '/p/review.md' },
      { name = 'deploy', description = 'Deploy', source = 'extension' },
      { name = 'skill:lint', description = 'Lint', source = 'skill', path = '/s/SKILL.md' },
    }

    it('lists commands, skills and user commands from get_commands', function()
      open({ commands = commands })
      assert.equals(3, #ops().list_commands(connection, location()):wait())
      local skills = ops().list_skills(connection, location()):wait()
      assert.equals('lint', skills[1].name)
      assert.equals('/skill:lint', skills[1].content)
      local user_commands = ops().get_user_commands(connection, location()):wait()
      assert.is_truthy(user_commands.review)
      assert.is_truthy(user_commands.deploy)
      assert.is_nil(user_commands['skill:lint'])
    end)

    it('runs a command as a leading slash in a prompt', function()
      open({ commands = commands, state = { sessionId = 's' } })
      assert.is_true(ops().send_command(connection, 's', location(), { command = 'review', arguments = 'src' }):wait())
      assert.equals('/review src', ctx:received_of('prompt')[1].message)
    end)

    it('runs a command without arguments and applies its model first', function()
      open({ commands = commands, models = { sonnet, gpt }, state = { sessionId = 's', model = gpt } })
      ops().send_command(connection, 's', location(), { command = 'deploy', model = 'anthropic/sonnet' }):wait()
      assert.equals('/deploy', ctx:received_of('prompt')[1].message)
      assert.equals('sonnet', ctx:received_of('set_model')[1].modelId)
    end)

    it('rejects a malformed command model', function()
      open({ commands = commands })
      assert.matches(
        'provider/model',
        fails(function()
          ops().send_command(connection, 'fake-session', location(), { command = 'deploy', model = 'nope' }):wait()
        end)
      )
      assert.equals(0, #ctx:received_of('prompt'))
    end)
  end)

  describe('session operations', function()
    it('renames the session and updates its observed title', function()
      open({ state = { sessionId = 's' } })
      assert.is_true(ops().rename_session(connection, 's', location(), 'Better name'):wait())
      assert.equals('Better name', ctx:received_of('set_session_name')[1].name)
      assert.equals('Better name', observation:read().session.title)
    end)

    it('refuses an empty title', function()
      open({ state = { sessionId = 's' } })
      assert.matches(
        'empty',
        fails(function()
          ops().rename_session(connection, 's', location(), ''):wait()
        end)
      )
      assert.equals(0, #ctx:received_of('set_session_name'))
    end)

    it('compacts the session', function()
      open({ state = { sessionId = 's' } })
      assert.is_truthy(ops().summarize_session(connection, 's', location()):wait().id)
      assert.equals(1, #ctx:received_of('compact'))
    end)

    it('clones the whole session when no message is given', function()
      open({ state = { sessionId = 's' } })
      local forked = ops().fork_session(connection, 's', location(), {}):wait()
      assert.matches('^fake%-fork', forked.id)
      assert.equals(1, #ctx:received_of('clone'))
      assert.equals(forked.id, connection.pi.session_id)
    end)

    it('forks at the pi entry matching the Nth user message', function()
      open({
        state = { sessionId = 's' },
        messages = { user(1, 'one'), { role = 'assistant', timestamp = 2, content = {} }, user(3, 'two') },
        fork_messages = { { entryId = 'e1', text = 'one' }, { entryId = 'e2', text = 'two' } },
      })
      local second = observation:read().entry_order[3]
      local forked = ops().fork_session(connection, 's', location(), { messageID = second }):wait()
      assert.equals('e2', ctx:received_of('fork')[1].entryId)
      assert.matches('^fake%-fork', forked.id)
    end)

    it('fails when the message has no fork point', function()
      open({ state = { sessionId = 's' }, messages = { user(1, 'one') }, fork_messages = {} })
      assert.matches(
        'no fork point',
        fails(function()
          ops().fork_session(connection, 's', location(), { messageID = observation:read().entry_order[1] }):wait()
        end)
      )
      assert.equals(0, #ctx:received_of('fork'))
    end)

    it('fails when pi cancels the fork', function()
      open({ state = { sessionId = 's' }, cancel_fork = true })
      assert.matches(
        'refused',
        fails(function()
          ops().fork_session(connection, 's', location(), {}):wait()
        end)
      )
    end)

    it('keeps delete, revert, unrevert and share explicitly unsupported', function()
      open({ state = { sessionId = 's' } })
      for _, name in ipairs({ 'delete_session', 'revert_message', 'unrevert_messages' }) do
        assert.matches(
          'does not support ' .. name,
          fails(function()
            ops()[name](connection, 's', location(), {}):wait()
          end)
        )
      end
      assert.matches(
        'does not support share_session',
        fails(function()
          ops().share_session(connection, 's')
        end)
      )
    end)
  end)

  describe('crashed process', function()
    it('fails read operations until the user starts new work', function()
      open({ state = { sessionId = 's' }, after = { prompt = { { exit = 1 } } } })
      observation:submit({ text = 'die' }):wait()
      wait_for(function()
        return process.get().process.crashed
      end)
      assert.matches(
        'exited unexpectedly',
        fails(function()
          ops().get_model_catalog(connection, location()):wait()
        end)
      )
      assert.matches(
        'exited unexpectedly',
        fails(function()
          ops().rename_session(connection, 's', location(), 'x'):wait()
        end)
      )
      assert.is_false(process.get().process:is_running())
    end)

    it('restarts explicitly when submitting new work', function()
      open({ state = { sessionId = 's' }, after_runs = { prompt = { { { exit = 1 } } } } })
      observation:submit({ text = 'die' }):wait()
      wait_for(function()
        return process.get().process.crashed
      end)
      observation:submit({ text = 'again' }):wait()
      assert.is_true(process.get().process:is_running())
      assert.is_false(process.get().process.crashed)
      assert.equals('again', ctx:received_of('prompt')[2].message)
    end)
  end)
end)
