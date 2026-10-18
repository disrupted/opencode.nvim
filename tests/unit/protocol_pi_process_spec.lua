local fake_pi = require('tests.mocks.fake_pi_support')
local process = require('opencode.protocols.pi.process')

describe('pi process (fake pi over stdio)', function()
  local ctx, events, unsubscribe

  local function start(script)
    ctx = fake_pi.start(script)
    events = {}
    unsubscribe = process.on_event(function(event)
      events[#events + 1] = event
    end)
    return process.get()
  end

  local function wait_for(predicate)
    assert.is_true(vim.wait(5000, predicate, 10), 'timed out waiting for condition')
  end

  local function event_types()
    return vim.tbl_map(function(event)
      return event.type
    end, events)
  end

  after_each(function()
    unsubscribe()
    ctx:stop()
  end)

  it('launches the configured executable in rpc mode', function()
    local client = start({})
    client:get_state():wait()
    local argv = ctx:received()[1].argv
    assert.is_truthy(vim.tbl_contains(argv, '--mode'))
    assert.is_truthy(vim.tbl_contains(argv, 'rpc'))
  end)

  it('rejects when the executable is missing', function()
    local client = start({})
    require('opencode.config').values.pi.executable = vim.fs.joinpath(ctx.root, 'missing')
    client.process:stop()
    local ok, err = pcall(function()
      client:get_state():wait()
    end)
    assert.is_false(ok)
    assert.matches('command not found', err)
  end)

  it('frames requests with unique ids and resolves each from its own response', function()
    local client = start({ state = { sessionId = 's1' }, messages = { { role = 'user', content = 'hi' } } })
    local state_promise, messages_promise = client:get_state(), client:get_messages()
    assert.equals('s1', state_promise:wait().sessionId)
    assert.equals('hi', messages_promise:wait().messages[1].content)
    local received = ctx:received()
    assert.are_not.equals(received[2].id, received[3].id)
    assert.equals('get_state', received[2].type)
    assert.equals('get_messages', received[3].type)
  end)

  it('rejects a request when pi answers success = false', function()
    local client = start({ replies = { get_messages = { error = 'boom' } } })
    local ok, err = pcall(function()
      client:get_messages():wait()
    end)
    assert.is_false(ok)
    assert.equals('boom', err)
  end)

  it('does not route responses to event listeners', function()
    local client = start({})
    client:get_state():wait()
    assert.same({}, events)
  end)

  it('routes unsolicited events to listeners in order', function()
    local client = start({
      on_start = { { event = { type = 'one' } }, { event = { type = 'two' } } },
    })
    client:get_state():wait()
    wait_for(function()
      return #events >= 2
    end)
    assert.same({ 'one', 'two' }, event_types())
  end)

  it('reassembles records split across writes and tolerates CRLF and junk lines', function()
    local client = start({
      on_start = {
        { chunks = { '{"type":"spl', 'it","n":1}\n' } },
        { raw = 'not json\n' },
        { raw = '{"type":"crlf"}\r\n' },
        { raw = '\n' },
        { event = { type = 'after' } },
      },
    })
    client:get_state():wait()
    wait_for(function()
      return #events >= 3
    end)
    assert.same({ 'split', 'crlf', 'after' }, event_types())
    assert.equals(1, events[1].n)
  end)

  it('stops delivering to an unsubscribed listener', function()
    local client = start({ after = { get_state = { { event = { type = 'late' } } } } })
    local seen = {}
    local off = process.on_event(function(event)
      seen[#seen + 1] = event.type
    end)
    off()
    client:get_state():wait()
    wait_for(function()
      return #events >= 1
    end)
    assert.same({}, seen)
  end)

  it('keeps one listener failing from starving the others', function()
    local client = start({ after = { get_state = { { event = { type = 'ping' } } } } })
    local off = process.on_event(function()
      error('listener bug')
    end)
    client:get_state():wait()
    wait_for(function()
      return #events >= 1
    end)
    off()
    assert.same({ 'ping' }, event_types())
  end)

  it('reads the active session through get_state and get_messages', function()
    local client = start({ state = { sessionId = 'abc', sessionFile = '/x/abc.jsonl' } })
    assert.equals('abc', client:get_state():wait().sessionId)
    assert.same({}, client:get_messages():wait().messages)
  end)

  it('switches session by file and then reports the new session', function()
    local client = start({ state = { sessionId = 'first' } })
    local path = ctx:write_session('second.jsonl', { id = 'second', cwd = '/w' }, {
      { role = 'user', timestamp = 1, content = 'earlier' },
    })
    local result = client:switch_session(path):wait()
    assert.is_false(result.cancelled)
    assert.equals('second', client:get_state():wait().sessionId)
    assert.equals('earlier', client:get_messages():wait().messages[1].content)
    assert.equals(path, ctx:received_of('switch_session')[1].sessionPath)
  end)

  it('surfaces a refused switch as cancelled', function()
    local client = start({ cancel_switch = true })
    local path = ctx:write_session('x.jsonl', { id = 'x', cwd = '/w' })
    assert.is_true(client:switch_session(path):wait().cancelled)
  end)

  it('starts a fresh session on new_session', function()
    local client = start({ state = { sessionId = 'old' } })
    assert.is_false(client:new_session():wait().cancelled)
    assert.are_not.equals('old', client:get_state():wait().sessionId)
  end)

  it('streams a prompt: text, thinking and a tool call with its result', function()
    local client = start({
      after = {
        prompt = {
          { event = { type = 'agent_start' } },
          { event = { type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = 'hm' } } },
          { event = { type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'ok' } } },
          { event = { type = 'tool_execution_start', toolCallId = 'c1', toolName = 'bash' } },
          {
            event = {
              type = 'tool_execution_end',
              toolCallId = 'c1',
              result = { content = { { type = 'text', text = 'out' } } },
            },
          },
          { event = { type = 'agent_settled' } },
        },
      },
    })
    client:prompt('go'):wait()
    wait_for(function()
      return #events >= 6
    end)
    assert.same({
      'agent_start',
      'message_update',
      'message_update',
      'tool_execution_start',
      'tool_execution_end',
      'agent_settled',
    }, event_types())
    assert.equals('go', ctx:received_of('prompt')[1].message)
  end)

  it('queues a prompt sent while the agent runs as a steer', function()
    local client = start({ after = { prompt = { { event = { type = 'agent_start' } } } } })
    client:prompt('first'):wait()
    wait_for(function()
      return #events >= 1
    end)
    client:prompt('second'):wait()
    local prompts = ctx:received_of('prompt')
    assert.is_nil(prompts[1].streamingBehavior)
    assert.equals('steer', prompts[2].streamingBehavior)
  end)

  it('stops steering once the agent settles', function()
    local client = start({
      after = { prompt = { { event = { type = 'agent_start' } }, { event = { type = 'agent_settled' } } } },
    })
    client:prompt('first'):wait()
    wait_for(function()
      return #events >= 2
    end)
    client:prompt('second'):wait()
    assert.is_nil(ctx:received_of('prompt')[2].streamingBehavior)
  end)

  it('sends abort', function()
    local client = start({ after = { abort = { { event = { type = 'agent_settled' } } } } })
    client:abort():wait()
    wait_for(function()
      return #events >= 1
    end)
    assert.equals(1, #ctx:received_of('abort'))
  end)

  describe('process exit', function()
    it('rejects in-flight requests and emits an unexpected process_exit', function()
      local client = start({ silent = { never_answered = true }, after = { prompt = { { exit = 3 } } } })
      client:get_state():wait()
      local pending = client:request({ type = 'never_answered' })
      local failure
      pending:catch(function(err)
        failure = err
      end)
      client:prompt('die'):wait()
      wait_for(function()
        return failure ~= nil
      end)
      assert.matches('exited', failure)
      wait_for(function()
        return vim.iter(events):any(function(event)
          return event.type == 'process_exit'
        end)
      end)
      local exit = vim.iter(events):find(function(event)
        return event.type == 'process_exit'
      end)
      assert.equals(3, exit.code)
      assert.is_false(exit.expected)
      assert.is_false(client.process:is_running())
    end)

    it('marks a requested stop as expected', function()
      local client = start({})
      client:get_state():wait()
      client.process:stop()
      wait_for(function()
        return #events >= 1
      end)
      assert.is_true(events[1].expected)
    end)

    it('fails requests after a crash instead of silently restarting', function()
      local client = start({ after = { prompt = { { exit = 1 } } } })
      client:get_state():wait()
      client:prompt('die'):wait()
      wait_for(function()
        return client.process.crashed
      end)
      local ok, err = pcall(function()
        client:get_state():wait()
      end)
      assert.is_false(ok)
      assert.matches('exited unexpectedly', tostring(err))
      assert.is_false(client.process:is_running())
      assert.equals(1, #vim.tbl_filter(function(record)
        return record.argv ~= nil
      end, ctx:received()))
    end)

    it('restarts a crashed process when asked to', function()
      local client = start({ after = { prompt = { { exit = 1 } } } })
      client:get_state():wait()
      client:prompt('die'):wait()
      wait_for(function()
        return not client.process:is_running()
      end)
      client.process:restart():wait()
      assert.equals('fake-session', client:get_state():wait().sessionId)
      assert.is_true(client.process:is_running())
      assert.equals(2, #vim.tbl_filter(function(record)
        return record.argv ~= nil
      end, ctx:received()))
    end)

    it('does not mistake a stopped process exiting late for the restarted one', function()
      local client = start({})
      client:get_state():wait()
      client.process:stop()
      client:get_state():wait()
      vim.wait(300)
      assert.is_true(client.process:is_running())
      assert.equals('fake-session', client:get_state():wait().sessionId)
    end)

    it('forgets a running agent when the process dies', function()
      local client = start({ after = { prompt = { { event = { type = 'agent_start' } }, { exit = 1 } } } })
      client:prompt('go'):wait()
      wait_for(function()
        return not client.process:is_running()
      end)
      client.process:restart():wait()
      client:prompt('again'):wait()
      assert.is_nil(ctx:received_of('prompt')[2].streamingBehavior)
    end)
  end)
end)
