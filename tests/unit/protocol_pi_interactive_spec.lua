local fake_pi = require('tests.mocks.fake_pi_support')
local adapter = require('opencode.protocols.pi.connection')
local process = require('opencode.protocols.pi.process')
local log = require('opencode.log')
local stub = require('luassert.stub')

describe('pi interactive surface over a fake pi process', function()
  local ctx, connection, observation, unwatch, notify, autocmds, autocmd_id

  local function wait_for(predicate, message)
    assert.is_true(vim.wait(5000, predicate, 10), message or 'timed out waiting for condition')
  end

  local function ev(event)
    return { event = event }
  end

  local function ui(event)
    return ev(vim.tbl_extend('force', { type = 'extension_ui_request' }, event))
  end

  local function user(timestamp, text)
    return { role = 'user', timestamp = timestamp, content = { { type = 'text', text = text } } }
  end

  local function open(script)
    ctx = fake_pi.start(script)
    local session_id = (script.state and script.state.sessionId) or 'fake-session'
    connection = adapter.start_server():wait()
    observation = connection:observe({ id = session_id, location = { directory = vim.fn.getcwd() } })
    unwatch = observation:watch({ 'session', 'messages', 'execution', 'permissions', 'questions' }, function() end)
    wait_for(function()
      local sync = observation:read().sync
      return sync.messages.state == 'current' and sync.execution.state == 'current'
    end, 'observation never became current')
  end

  ---Dialogs arrive while a prompt is being handled, after the admission is registered.
  local function run(events)
    return { prompt = vim.list_extend({ { sleep = 40 }, ev({ type = 'agent_start' }) }, events) }
  end

  local function entries()
    local state = observation:read()
    return vim.tbl_map(function(id)
      return state.entries_by_id[id]
    end, state.entry_order)
  end

  local function pending(kind)
    local requests = observation:read()[kind .. '_requests_by_id']
    return requests[next(requests)]
  end

  local function types_of(command_type)
    return ctx:received_of(command_type)
  end

  before_each(function()
    notify = stub(log, 'notify')
    autocmds = {}
    autocmd_id = vim.api.nvim_create_autocmd('User', {
      pattern = 'OpencodeEvent:*',
      callback = function(args)
        autocmds[#autocmds + 1] = args.data.event
      end,
    })
  end)

  after_each(function()
    vim.api.nvim_del_autocmd(autocmd_id)
    notify:revert()
    if unwatch then
      unwatch()
    end
    if connection then
      connection:close()
    end
    unwatch, connection, observation = nil, nil, nil
    ctx:stop()
  end)

  local function fired(event_type)
    return vim.tbl_filter(function(event)
      return event.type == event_type
    end, autocmds)
  end

  describe('extension ui requests', function()
    it('marks permissions and questions supported and keeps the rest unsupported', function()
      open({ state = { sessionId = 's' } })
      local sync = observation:read().sync
      assert.equals('current', sync.permissions.state)
      assert.equals('current', sync.questions.state)
      assert.equals('unsupported', sync.inbox.state)
      assert.equals('unsupported', sync.files.state)
    end)

    it('maps confirm to a permission and answers it with confirmed', function()
      open({
        state = { sessionId = 's' },
        after = run({ ui({ id = 'u1', method = 'confirm', title = 'Clear?', message = 'All gone' }) }),
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return pending('permission') ~= nil
      end)
      local request = pending('permission')
      assert.equals('u1', request.id)
      assert.equals('All gone', request.message)
      assert.equals('Clear?', request.preview.title)
      assert.same(
        { 'once', 'reject' },
        vim.tbl_map(function(c)
          return c.value
        end, request.choices)
      )

      assert.is_true(observation:reply_permission('u1', { choice = 'once' }):wait())
      wait_for(function()
        return #types_of('extension_ui_response') == 1
      end)
      local reply = types_of('extension_ui_response')[1]
      assert.equals('u1', reply.id)
      assert.is_true(reply.confirmed)
      assert.is_nil(pending('permission'))
    end)

    it('answers a declined confirm with confirmed=false and rejects unknown choices', function()
      open({ state = { sessionId = 's' }, after = run({ ui({ id = 'u1', method = 'confirm', title = 'Sure?' }) }) })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return pending('permission') ~= nil
      end)
      assert.has_error(function()
        observation:reply_permission('u1', { choice = 'always' })
      end, 'invalid permission answer')
      observation:reply_permission('u1', { choice = 'reject' }):wait()
      wait_for(function()
        return #types_of('extension_ui_response') == 1
      end)
      assert.is_false(types_of('extension_ui_response')[1].confirmed)
    end)

    it('maps select to a question limited to its options', function()
      open({
        state = { sessionId = 's' },
        after = run({ ui({ id = 'u2', method = 'select', title = 'Allow?', options = { 'Allow', 'Block' } }) }),
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return pending('question') ~= nil
      end)
      local field = pending('question').fields[1]
      assert.equals('value', field.key)
      assert.is_false(field.custom)
      assert.same(
        { 'Allow', 'Block' },
        vim.tbl_map(function(o)
          return o.value
        end, field.options)
      )

      assert.has_error(function()
        observation:reply_question('u2', { value = 'Maybe' })
      end, 'invalid answer for question field value')
      observation:reply_question('u2', { value = 'Block' }):wait()
      wait_for(function()
        return #types_of('extension_ui_response') == 1
      end)
      assert.equals('Block', types_of('extension_ui_response')[1].value)
      assert.is_nil(pending('question'))
    end)

    it('maps input and editor to free-form questions and cancels with cancelled=true', function()
      open({
        state = { sessionId = 's' },
        after = run({
          ui({ id = 'i1', method = 'input', title = 'Name', placeholder = 'type' }),
          ui({ id = 'e1', method = 'editor', title = 'Edit', prefill = 'Line 1' }),
        }),
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return vim.tbl_count(observation:read().question_requests_by_id) == 2
      end)
      local requests = observation:read().question_requests_by_id
      assert.is_true(requests.i1.fields[1].custom)
      assert.same({}, requests.i1.fields[1].options)
      assert.equals('Line 1', requests.e1.fields[1].options[1].value)

      observation:reply_question('i1', { value = 'bob' }):wait()
      observation:reject_question('e1'):wait()
      wait_for(function()
        return #types_of('extension_ui_response') == 2
      end)
      local replies = types_of('extension_ui_response')
      assert.equals('bob', replies[1].value)
      assert.is_true(replies[2].cancelled)
      assert.same({}, observation:read().question_requests_by_id)
    end)

    it('forwards notify with its level', function()
      open({
        state = { sessionId = 's' },
        after = run({ ui({ id = 'n1', method = 'notify', message = 'Blocked', notifyType = 'warning' }) }),
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return #notify.calls > 0
      end)
      assert.stub(notify).was_called_with('Blocked', vim.log.levels.WARN)
    end)

    it('tells the user once about methods it cannot show, but not about footer decorations', function()
      open({
        state = { sessionId = 's' },
        after = run({
          ui({ id = 's1', method = 'setStatus', statusKey = 'k' }),
          ui({ id = 'w1', method = 'setWidget', widgetKey = 'k' }),
          ui({ id = 'e1', method = 'set_editor_text', text = 'a' }),
          ui({ id = 'e2', method = 'set_editor_text', text = 'b' }),
          ui({ id = 'x1', method = 'somethingNew' }),
        }),
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return #notify.calls >= 2
      end)
      vim.wait(100)
      assert.equals(2, #notify.calls)
      assert.matches('set_editor_text', notify.calls[1].refs[1])
      assert.matches('somethingNew', notify.calls[2].refs[1])
    end)

    it('drops a dialog locally when its timeout passes, without answering', function()
      open({
        state = { sessionId = 's' },
        after = run({ ui({ id = 't1', method = 'confirm', title = 'Hurry', timeout = 50 }) }),
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return pending('permission') ~= nil
      end)
      wait_for(function()
        return pending('permission') == nil
      end)
      assert.equals(0, #types_of('extension_ui_response'))
    end)

    it('declines a dialog nobody is observing so the extension is not blocked', function()
      open({
        state = { sessionId = 's' },
        after = { get_commands = { ui({ id = 'x1', method = 'confirm', title = 'Anyone?' }) } },
      })
      unwatch()
      unwatch = nil
      assert.is_nil(connection.observations.s)
      process.get():get_commands():wait()
      wait_for(function()
        return #types_of('extension_ui_response') == 1
      end)
      assert.is_true(types_of('extension_ui_response')[1].cancelled)
    end)

    it('cancels open dialogs when their last watcher goes away', function()
      open({ state = { sessionId = 's' }, after = run({ ui({ id = 'r1', method = 'confirm', title = 'Hm' }) }) })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return pending('permission') ~= nil
      end)
      unwatch()
      unwatch = nil
      wait_for(function()
        return #types_of('extension_ui_response') == 1
      end)
      assert.is_true(types_of('extension_ui_response')[1].cancelled)
    end)

    it('emits permission and form events', function()
      open({
        state = { sessionId = 's' },
        after = run({
          ui({ id = 'u1', method = 'confirm', title = 'Sure?' }),
          ui({ id = 'u2', method = 'select', title = 'Pick', options = { 'a' } }),
        }),
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return #fired('permission.asked') == 1 and #fired('form.created') == 1
      end)
      observation:reply_permission('u1', { choice = 'once' }):wait()
      observation:reject_question('u2'):wait()
      assert.equals('u1', fired('permission.replied')[1].properties.requestID)
      assert.equals('s', fired('permission.asked')[1].properties.sessionID)
      assert.equals('u2', fired('form.cancelled')[1].properties.id)
    end)
  end)

  describe('queued messages', function()
    local function queue(steering, follow_up)
      return ev({ type = 'queue_update', steering = steering or {}, followUp = follow_up or {} })
    end

    local function queued()
      return vim.tbl_filter(function(entry)
        return entry.queued
      end, entries())
    end

    local function texts()
      return vim.tbl_map(function(entry)
        return entry.content[1].text
      end, queued())
    end

    it('surfaces steer and follow-up as queued user entries and clears them when consumed', function()
      open({
        state = { sessionId = 's' },
        after_runs = {
          prompt = {
            { { sleep = 40 }, ev({ type = 'agent_start' }) },
            { queue({ 'change course' }, { 'then tidy' }) },
          },
        },
        after = {
          get_commands = {
            queue({}, { 'then tidy' }),
            ev({ type = 'message_start', message = user(7, 'change course') }),
            ev({ type = 'message_end', message = user(7, 'change course') }),
          },
        },
      })
      observation:submit({ text = 'go' }):wait()
      local steer_id
      observation
        :submit({
          text = 'change course',
          id = 'steer-1',
        })
        :wait()
      wait_for(function()
        return #queued() == 2
      end)
      assert.same({ 'change course', 'then tidy' }, texts())
      steer_id = queued()[1].id
      assert.equals('steer-1', steer_id)
      assert.is_true(queued()[1].queued)
      assert.equals('user', queued()[1].kind)

      process.get():get_commands():wait()
      wait_for(function()
        return #queued() == 1
      end)
      assert.same({ 'then tidy' }, texts())
      wait_for(function()
        return observation:read().entries_by_id[steer_id] ~= nil
      end)
      local consumed = observation:read().entries_by_id[steer_id]
      assert.is_not_nil(consumed)
      assert.is_nil(consumed.queued)
      local order = observation:read().entry_order
      assert.equals(steer_id, order[#order - 1])
      assert.equals(queued()[1].id, order[#order])
    end)

    it('keeps queued entries trailing the transcript and across a history reload', function()
      open({
        state = { sessionId = 's' },
        after = run({ queue({ 'later' }) }),
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return #queued() == 1
      end)
      observation:_start_resource('messages')
      wait_for(function()
        return observation:read().sync.messages.state == 'current'
      end)
      vim.wait(50)
      assert.same({ 'later' }, texts())
      local order = observation:read().entry_order
      assert.is_true(observation:read().entries_by_id[order[#order]].queued)
    end)

    it('drops the queue and open dialogs when pi exits unexpectedly', function()
      open({
        state = { sessionId = 's' },
        after_runs = { prompt = { { { sleep = 40 }, ev({ type = 'agent_start' }) } } },
        after = {
          get_commands = {
            ev({ type = 'queue_update', steering = { 'x' }, followUp = {} }),
            ui({ id = 'd1', method = 'confirm', title = 'Hm' }),
            { sleep = 100 },
            { exit = 1 },
          },
        },
      })
      observation:submit({ text = 'go' }):wait()
      process.get():get_commands():wait()
      wait_for(function()
        return #queued() == 1 and pending('permission') ~= nil
      end)
      wait_for(function()
        return #queued() == 0 and pending('permission') == nil
      end)
      assert.equals('failed', observation:read().execution.last_outcome)
    end)

    it('steers by default while a run is active and follows up on request', function()
      open({ state = { sessionId = 's' }, after = run({}) })
      observation:submit({ text = 'first' }):wait()
      wait_for(function()
        return observation:read().execution.activity == 'running'
      end)
      observation:submit({ text = 'second' }):wait()
      connection.operations.submit(connection, 's', { text = 'third', delivery = 'follow_up' }):wait()
      local prompts = types_of('prompt')
      assert.is_nil(prompts[1].streamingBehavior)
      assert.equals('steer', prompts[2].streamingBehavior)
      assert.equals('followUp', prompts[3].streamingBehavior)
    end)
  end)

  describe('run end safety', function()
    it('ends the run on agent_end without a retry, even if agent_settled never comes', function()
      open({ state = { sessionId = 's' }, after = run({ ev({ type = 'agent_end', willRetry = false }) }) })
      local outcome = observation:submit({ text = 'go' }):wait().completion:wait()
      assert.equals('succeeded', outcome.outcome)
      assert.equals('idle', observation:read().execution.activity)
      assert.equals(1, #fired('session.execution.succeeded'))
    end)

    it('does not end the run on agent_end while messages are still queued', function()
      open({
        state = { sessionId = 's' },
        after = run({
          ev({ type = 'queue_update', steering = {}, followUp = { 'more' } }),
          ev({ type = 'agent_end', willRetry = false }),
        }),
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return #observation._pi_queued == 1
      end)
      vim.wait(100)
      assert.equals('running', observation:read().execution.activity)
    end)

    it('fails the run when the final retry fails, without waiting for agent_settled', function()
      open({
        state = { sessionId = 's' },
        after = run({
          ev({ type = 'agent_end', willRetry = true }),
          ev({ type = 'auto_retry_start', attempt = 3, delayMs = 1 }),
          ev({ type = 'auto_retry_end', success = false, attempt = 3, finalError = 'gave up' }),
        }),
      })
      local outcome = observation:submit({ text = 'go' }):wait().completion:wait()
      assert.equals('failed', outcome.outcome)
      assert.matches('gave up', outcome.error.message)
      assert.equals('idle', observation:read().execution.activity)
    end)

    it('does not let a late agent_settled overwrite a failed outcome', function()
      open({
        state = { sessionId = 's' },
        after = run({
          ev({ type = 'auto_retry_start', attempt = 1, delayMs = 1 }),
          ev({ type = 'auto_retry_end', success = false, attempt = 1, finalError = 'nope' }),
          { sleep = 30 },
          ev({ type = 'agent_settled' }),
        }),
      })
      observation:submit({ text = 'go' }):wait().completion:wait()
      vim.wait(150)
      assert.equals('failed', observation:read().execution.last_outcome)
      assert.equals(1, #fired('session.execution.failed'))
      assert.equals(0, #fired('session.execution.succeeded'))
    end)

    it('runs a second prompt normally after an early agent_end', function()
      open({
        state = { sessionId = 's' },
        after_runs = {
          prompt = {
            { { sleep = 40 }, ev({ type = 'agent_start' }), ev({ type = 'agent_end', willRetry = false }) },
            { { sleep = 40 }, ev({ type = 'agent_start' }), ev({ type = 'agent_end', willRetry = false }) },
          },
        },
      })
      assert.equals('succeeded', observation:submit({ text = 'a' }):wait().completion:wait().outcome)
      assert.equals('succeeded', observation:submit({ text = 'b' }):wait().completion:wait().outcome)
      assert.equals(2, #fired('session.execution.started'))
      assert.equals(2, #fired('session.execution.succeeded'))
    end)
  end)

  describe('opencode events', function()
    it('emits execution, retry and interruption events with the session id', function()
      open({
        state = { sessionId = 's' },
        after = run({
          ev({ type = 'auto_retry_start', attempt = 1, delayMs = 10, errorMessage = 'busy' }),
          ev({ type = 'auto_retry_end', success = true, attempt = 1 }),
          ev({
            type = 'message_end',
            message = { role = 'assistant', stopReason = 'aborted', content = {}, timestamp = 3 },
          }),
          ev({ type = 'agent_settled' }),
        }),
      })
      observation:submit({ text = 'go' }):wait().completion:wait()
      assert.equals('s', fired('session.execution.started')[1].properties.sessionID)
      assert.equals(1, fired('session.retry.scheduled')[1].properties.attempt)
      assert.equals('busy', fired('session.retry.scheduled')[1].properties.message)
      assert.equals('s', fired('session.execution.interrupted')[1].properties.sessionID)
    end)

    it('drives the done-thinking hook through the shared session events', function()
      local runtime = require('opencode.services.session_runtime')
      local completed = {}
      local original = runtime.on_session_request_completed
      runtime.on_session_request_completed = function(session_id)
        completed[#completed + 1] = session_id
      end
      runtime.setup_done_thinking_events(true)
      open({ state = { sessionId = 's' }, after = run({ ev({ type = 'agent_settled' }) }) })
      observation:submit({ text = 'go' }):wait().completion:wait()
      wait_for(function()
        return #completed == 1
      end)
      assert.same({ 's' }, completed)
      runtime.on_session_request_completed = original
      runtime.setup_done_thinking_events(false)
    end)
  end)

  describe('cycling', function()
    local server_job = require('opencode.server_job')
    local agent_model = require('opencode.services.agent_model')
    local agent = require('opencode.commands.handlers.agent')
    local state = require('opencode.state')
    local Promise = require('opencode.promise')

    local sonnet = { id = 'sonnet', name = 'Sonnet', provider = 'anthropic', reasoning = true }
    local gpt = { id = 'gpt', name = 'GPT', provider = 'openai', reasoning = false }
    local ensure

    before_each(function()
      state.model.set_model(nil)
      state.model.set_variant(nil)
    end)

    after_each(function()
      ensure:revert()
      state.jobs.clear_server()
      state.model.set_model(nil)
      state.model.set_variant(nil)
    end)

    local function open_cycling(script)
      open(script)
      ensure = stub(server_job, 'ensure_server').returns(Promise.new():resolve(connection))
      state.jobs.set_server(connection)
    end

    it('cycles the thinking level through the existing cycle_variant action', function()
      open_cycling({
        state = { sessionId = 's', model = sonnet, thinkingLevel = 'off' },
        models = { sonnet, gpt },
      })
      agent_model.cycle_variant():wait()
      assert.equals('minimal', state.current_variant)
      assert.equals(1, #types_of('cycle_thinking_level'))
    end)

    it('says so when the model has no thinking levels', function()
      open_cycling({ state = { sessionId = 's', model = gpt }, models = { sonnet, gpt } })
      agent_model.cycle_variant():wait()
      assert.is_nil(state.current_variant)
      assert.stub(notify).was_called_with('Current model does not support thinking levels', vim.log.levels.WARN)
    end)

    it('cycles models through the agent-mode key and mirrors the selection', function()
      open_cycling({
        state = { sessionId = 's', model = sonnet, thinkingLevel = 'low' },
        models = { sonnet, gpt },
      })
      agent.actions.switch_mode():wait()
      assert.equals('openai/gpt', state.current_model)
      assert.equals(1, #types_of('cycle_model'))
      agent.actions.switch_mode():wait()
      assert.equals('anthropic/sonnet', state.current_model)
    end)

    it('explains when there is nothing to cycle to', function()
      open_cycling({ state = { sessionId = 's', model = sonnet }, models = { sonnet } })
      agent_model.cycle_model():wait()
      assert.is_nil(state.current_model)
      assert.stub(notify).was_called_with('No other model to cycle to', vim.log.levels.WARN)
    end)

    describe('against a connection without the optional capabilities', function()
      local config_file = require('opencode.config_file')

      before_each(function()
        open({ state = { sessionId = 's' } })
        local bare = { operations = {} }
        ensure = stub(server_job, 'ensure_server').returns(Promise.new():resolve(bare))
        state.jobs.set_server(bare)
      end)

      it('does not cycle models and says so', function()
        agent_model.cycle_model():wait()
        assert.is_nil(state.current_model)
        assert.stub(notify).was_called_with('Cycling models is not supported by this backend', vim.log.levels.WARN)
      end)

      it('falls back to the variant list of the model when it cannot cycle thinking levels', function()
        agent_model.cycle_variant():wait()
        assert.stub(notify).was_called_with('No model selected', vim.log.levels.WARN)
      end)

      it('switches agent modes instead of cycling models', function()
        local agents = stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'plan', 'build' }))
        local switch = stub(agent_model, 'switch_to_mode').returns(Promise.new():resolve(true))
        state.store.set('current_mode', 'plan')
        agent.actions.switch_mode():wait()
        assert.stub(switch).was_called_with('build')
        agents:revert()
        switch:revert()
      end)
    end)

    it('reports the single-agent capability only when the connection declares it', function()
      open_cycling({ state = { sessionId = 's' } })
      assert.is_true(agent_model.is_single_agent():wait())
      ensure:revert()
      ensure = stub(server_job, 'ensure_server').returns(Promise.new():resolve({ operations = {} }))
      assert.is_false(agent_model.is_single_agent():wait())
    end)

    it('registers cycle_model as a bindable command and api export', function()
      open_cycling({ state = { sessionId = 's' } })
      assert.is_not_nil(agent.command_defs.cycle_model)
      assert.is_function(require('opencode.api').cycle_model)
    end)
  end)
end)
