local fake_pi = require('tests.mocks.fake_pi_support')
local process = require('opencode.protocols.pi.process')
local adapter = require('opencode.protocols.pi.connection')

describe('pi protocol over a fake pi process', function()
  local ctx, connection, observation, unwatch, snapshots

  local function wait_for(predicate, message)
    assert.is_true(vim.wait(5000, predicate, 10), message or 'timed out waiting for condition')
  end

  local function ev(event)
    return { event = event }
  end

  local function text_message(role, timestamp, text, extra)
    return vim.tbl_extend('force', {
      role = role,
      timestamp = timestamp,
      content = { { type = 'text', text = text } },
    }, extra or {})
  end

  ---@param script table
  ---@param session_id? string
  local function open(script, session_id)
    ctx = fake_pi.start(script)
    session_id = session_id or (script.state and script.state.sessionId) or 'fake-session'
    connection = adapter.start_server():wait()
    observation = connection:observe({ id = session_id, location = { directory = vim.fn.getcwd() } })
    snapshots = {}
    unwatch = observation:watch({ 'session', 'messages', 'execution' }, function(changed)
      local ids = {}
      for _, entry_id in ipairs(changed:read().entry_order) do
        for _, part in ipairs(changed:read().entries_by_id[entry_id].content) do
          ids[#ids + 1] = entry_id .. '/' .. part.id
        end
      end
      snapshots[#snapshots + 1] = ids
    end)
    wait_for(function()
      local sync = observation:read().sync
      return sync.messages.state == 'current' and sync.session.state == 'current' and sync.execution.state == 'current'
    end, 'observation never became current')
    return observation:read()
  end

  local function entries()
    local state = observation:read()
    return vim.tbl_map(function(id)
      return state.entries_by_id[id]
    end, state.entry_order)
  end

  local function parts_of(entry, kind)
    return vim.tbl_filter(function(part)
      return part.kind == kind
    end, entry.content)
  end

  local function activity()
    return observation:read().execution.activity
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

  describe('connection', function()
    it('reports health from the process and carries the active session', function()
      ctx = fake_pi.start({ state = { sessionId = 'live' } })
      connection = adapter.start_server():wait()
      assert.equals('stdio', connection.kind)
      assert.equals('live', connection.pi.session_id)
      assert.is_true(connection:check_health():wait())
      process.get().process:stop()
      assert.is_false(connection:check_health():wait())
    end)

    it('stops the process when the connection closes', function()
      ctx = fake_pi.start({})
      connection = adapter.start_server():wait()
      connection:close():wait()
      assert.is_false(process.get().process:is_running())
    end)
  end)

  describe('history', function()
    it('loads get_messages with tool results merged into their call', function()
      local call = { type = 'toolCall', id = 'c1', name = 'bash', arguments = { command = 'ls' } }
      local state = open({
        state = { sessionId = 'h' },
        messages = {
          text_message('user', 1, 'list'),
          { role = 'assistant', timestamp = 2, content = { { type = 'thinking', thinking = 'hm' }, call } },
          {
            role = 'toolResult',
            timestamp = 3,
            toolCallId = 'c1',
            toolName = 'bash',
            content = { { type = 'text', text = 'a.txt' } },
          },
        },
      })
      assert.equals(2, #state.entry_order)
      local assistant = state.entries_by_id[state.entry_order[2]]
      assert.equals(1, #parts_of(assistant, 'reasoning'))
      local tool = parts_of(assistant, 'tool')[1]
      assert.equals('completed', tool.state)
      assert.equals('a.txt', tool.result[1].text)
    end)

    it('switches the process to a stored session when listing its messages', function()
      open({ state = { sessionId = 'current' } })
      ctx:write_session(
        'other.jsonl',
        { id = 'other', cwd = vim.fn.getcwd() },
        { text_message('user', 1, 'old question') }
      )
      local page = connection.operations.list_messages(connection, 'other'):wait()
      assert.equals('old question', page.data[1].content[1].text)
      assert.equals(0, #ctx:received_of('switch_session'))
    end)
  end)

  describe('prompt streaming', function()
    local call = { type = 'toolCall', id = 'c1', name = 'bash', arguments = { command = 'ls' } }

    local function assistant(content, extra)
      return vim.tbl_extend('force', { role = 'assistant', timestamp = 200, content = content }, extra or {})
    end

    local function turn()
      local thinking = { type = 'thinking', thinking = 'plan' }
      local text = { type = 'text', text = 'Running' }
      return {
        ev({ type = 'agent_start' }),
        ev({ type = 'message_start', message = text_message('user', 100, 'go') }),
        ev({ type = 'message_end', message = text_message('user', 100, 'go') }),
        ev({ type = 'message_start', message = assistant({}) }),
        ev({ type = 'message_update', message = assistant({ thinking }) }),
        ev({ type = 'message_update', message = assistant({ thinking, text }) }),
        ev({ type = 'message_update', message = assistant({ thinking, text, call }) }),
        ev({ type = 'message_end', message = assistant({ thinking, text, call }, { stopReason = 'toolUse' }) }),
        ev({ type = 'tool_execution_start', toolCallId = 'c1', toolName = 'bash', args = call.arguments }),
        ev({
          type = 'tool_execution_end',
          toolCallId = 'c1',
          toolName = 'bash',
          result = { content = { { type = 'text', text = 'a.txt' } } },
          isError = false,
        }),
        ev({
          type = 'message_start',
          message = {
            role = 'toolResult',
            timestamp = 300,
            toolCallId = 'c1',
            toolName = 'bash',
            content = { { type = 'text', text = 'a.txt' } },
          },
        }),
        ev({
          type = 'message_end',
          message = {
            role = 'toolResult',
            timestamp = 300,
            toolCallId = 'c1',
            toolName = 'bash',
            content = { { type = 'text', text = 'a.txt' } },
          },
        }),
        ev({ type = 'message_start', message = text_message('assistant', 400, '') }),
        ev({ type = 'message_end', message = text_message('assistant', 400, 'Done', { stopReason = 'stop' }) }),
        ev({ type = 'agent_end' }),
        ev({ type = 'agent_settled' }),
      }
    end

    it('renders reasoning, text and a tool call with its result, without duplicates', function()
      open({ state = { sessionId = 's1' }, after = { prompt = turn() } })
      local submission = observation:submit({ text = 'go' }):wait()
      assert.is_truthy(submission)
      wait_for(function()
        return activity() == 'idle' and #entries() >= 3
      end)

      local list = entries()
      assert.same(
        { 'user', 'assistant', 'assistant' },
        vim.tbl_map(function(e)
          return e.kind
        end, list)
      )
      assert.equals('go', list[1].content[1].text)

      local first = list[2]
      assert.equals('plan', parts_of(first, 'reasoning')[1].text)
      assert.equals('Running', parts_of(first, 'text')[1].text)
      local tool = parts_of(first, 'tool')[1]
      assert.equals('completed', tool.state)
      assert.equals('a.txt', tool.result[1].text)
      assert.equals('Done', list[3].content[1].text)
      assert.equals('stop', list[3].finish)
    end)

    it('keeps one entry and stable part ids while a message streams', function()
      local text = function(value)
        return { { type = 'text', text = value } }
      end
      local script = {
        state = { sessionId = 's1' },
        after = {
          prompt = {
            ev({ type = 'agent_start' }),
            ev({ type = 'message_start', message = { role = 'assistant', content = {} } }),
            ev({ type = 'message_update', message = { role = 'assistant', content = text('a') } }),
            ev({ type = 'message_update', message = { role = 'assistant', content = text('ab') } }),
            ev({ type = 'message_update', message = { role = 'assistant', content = text('abc') } }),
          },
        },
      }
      open(script)
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        local list = entries()
        return #list >= 1 and list[#list].content[1] and list[#list].content[1].text == 'abc'
      end)
      local assistants = vim.tbl_filter(function(e)
        return e.kind == 'assistant'
      end, entries())
      assert.equals(1, #assistants)
    end)

    it('keeps part ids stable across planning, execution and the final message', function()
      open({ state = { sessionId = 's1' }, after = { prompt = turn() } })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return activity() == 'idle' and #entries() >= 3
      end)
      local final = snapshots[#snapshots]
      local seen_ids = {}
      for _, ids in ipairs(snapshots) do
        for _, id in ipairs(ids) do
          seen_ids[id] = true
        end
      end
      assert.is_true(#final >= 4)
      for id in pairs(seen_ids) do
        assert.is_true(vim.tbl_contains(final, id), 'part id vanished or changed: ' .. id)
      end
    end)

    it('keeps the identity of the optimistic prompt when pi echoes it', function()
      open({ state = { sessionId = 's1' }, after = { prompt = turn() } })
      local given
      observation
        :submit({ text = 'go', id = 'msg_mine' }, nil, function(id)
          given = id
        end)
        :wait()
      wait_for(function()
        return activity() == 'idle' and #entries() >= 1
      end)
      assert.equals('msg_mine', given)
      assert.equals('msg_mine', entries()[1].id)
    end)

    it('marks the observation running between agent_start and settle', function()
      open({
        state = { sessionId = 's1' },
        after = { prompt = { ev({ type = 'agent_start' }) } },
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return activity() == 'running'
      end)
      assert.equals('running', activity())
    end)

    it('resolves the submission when the agent settles', function()
      open({
        state = { sessionId = 's1' },
        after = { prompt = { ev({ type = 'agent_start' }), { sleep = 50 }, ev({ type = 'agent_settled' }) } },
      })
      local handle = observation:submit({ text = 'go' }):wait()
      local outcome = handle.completion:wait()
      assert.equals('succeeded', outcome.outcome)
      assert.equals('idle', activity())
    end)

    it('sends context blocks ahead of the prompt text', function()
      open({ state = { sessionId = 's1' } })
      observation:submit({ text = 'question', context = { { text = 'file contents' } } }):wait()
      local prompt = ctx:received_of('prompt')[1].message
      assert.equals('<context>\nfile contents\n</context>\n\nquestion', prompt)
    end)
  end)

  describe('abort', function()
    it('aborts the active session and ends the run as aborted', function()
      open({
        state = { sessionId = 's1' },
        after = {
          prompt = { ev({ type = 'agent_start' }) },
          abort = {
            ev({
              type = 'message_end',
              message = { role = 'assistant', timestamp = 9, content = {}, stopReason = 'aborted' },
            }),
            ev({ type = 'agent_end' }),
            ev({ type = 'agent_settled' }),
          },
        },
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return activity() == 'running'
      end)
      assert.is_true(observation:interrupt():wait())
      wait_for(function()
        return activity() == 'idle'
      end)
      assert.equals(1, #ctx:received_of('abort'))
      local last = entries()[#entries()]
      assert.equals('aborted', last.finish)
      assert.equals('interrupted', observation:read().execution.last_outcome)
      assert.matches('Pi stopped: aborted', last.content[1].text)
    end)

    it('does not abort a session that is not the active one', function()
      open({ state = { sessionId = 's1' } })
      assert.is_false(connection.operations.interrupt(connection, 'someone-else'):wait())
      assert.equals(0, #ctx:received_of('abort'))
    end)
  end)

  describe('error stop reasons', function()
    it('shows the error message of a failed turn with no content', function()
      open({
        state = { sessionId = 's1' },
        after = {
          prompt = {
            ev({ type = 'agent_start' }),
            ev({
              type = 'message_end',
              message = {
                role = 'assistant',
                timestamp = 9,
                content = {},
                stopReason = 'error',
                errorMessage = '429 rate limited',
              },
            }),
            ev({ type = 'agent_settled' }),
          },
        },
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return activity() == 'idle' and #entries() >= 1
      end)
      local last = entries()[#entries()]
      assert.equals('error', last.finish)
      assert.equals('failed', observation:read().execution.last_outcome)
      assert.matches('429 rate limited', observation:read().execution.error.message)
      assert.matches('429 rate limited', last.content[1].text)
    end)
  end)

  describe('session naming', function()
    it('updates the title of the active session on session_info_changed', function()
      open({
        state = { sessionId = 's1' },
        after = { prompt = { ev({ type = 'session_info_changed', name = 'Fix flaky test' }) } },
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return observation:read().session.title == 'Fix flaky test'
      end)
    end)
  end)

  describe('session switching', function()
    it('switches the process to the session being submitted to', function()
      open({ state = { sessionId = 'first' } })
      local second = ctx:write_session(
        'second.jsonl',
        { id = 'second', cwd = vim.fn.getcwd() },
        { text_message('user', 1, 'older') }
      )
      local other = connection:observe({ id = 'second', location = { directory = vim.fn.getcwd() } })
      other:submit({ text = 'continue' }):wait()
      local switches = ctx:received_of('switch_session')
      assert.equals(1, #switches)
      assert.equals(vim.fs.normalize(second), switches[1].sessionPath)
      assert.equals('second', connection.pi.session_id)
      assert.equals('continue', ctx:received_of('prompt')[1].message)
      assert.is_true(vim.fn.index(
        vim.tbl_map(function(r)
          return r.type
        end, ctx:received()),
        'switch_session'
      ) < vim.fn.index(
        vim.tbl_map(function(r)
          return r.type
        end, ctx:received()),
        'prompt'
      ))
    end)

    it('does not switch when already on the session', function()
      open({ state = { sessionId = 'first' } })
      observation:submit({ text = 'go' }):wait()
      assert.equals(0, #ctx:received_of('switch_session'))
    end)

    it('fails the submit when the session is unknown', function()
      open({ state = { sessionId = 'first' } })
      local ghost = connection:observe({ id = 'ghost' })
      local ok, err = pcall(function()
        ghost:submit({ text = 'x' }):wait()
      end)
      assert.is_false(ok)
      assert.matches('not found', tostring(err))
      assert.equals(0, #ctx:received_of('prompt'))
    end)

    it('fails the submit when pi refuses to switch', function()
      open({ state = { sessionId = 'first' }, cancel_switch = true })
      ctx:write_session('second.jsonl', { id = 'second', cwd = vim.fn.getcwd() })
      local other = connection:observe({ id = 'second' })
      local ok, err = pcall(function()
        other:submit({ text = 'x' }):wait()
      end)
      assert.is_false(ok)
      assert.matches('refused', tostring(err))
    end)

    it('creates a session through new_session', function()
      open({ state = { sessionId = 'first' } })
      local created = connection.operations.create_session(connection, { directory = '/w' }):wait()
      assert.matches('^fake%-new', created.id)
      assert.equals(created.id, connection.pi.session_id)
    end)
  end)

  describe('process exit', function()
    it('completes the submission as failed and idles the run when pi dies mid-turn', function()
      open({
        state = { sessionId = 's1' },
        after = { prompt = { ev({ type = 'agent_start' }), { sleep = 30 }, { exit = 1 } } },
      })
      local handle = observation:submit({ text = 'go' }):wait()
      local outcome = handle.completion:wait()
      assert.equals('failed', outcome.outcome)
      assert.matches('exited unexpectedly', outcome.error.message)
      wait_for(function()
        return activity() == 'idle'
      end, 'activity stayed running after the process died')
      assert.equals('failed', observation:read().execution.last_outcome)
    end)

    it('recovers after a restart by switching back to the session', function()
      open({
        state = { sessionId = 'first' },
        state_after_restart = { sessionId = 'fresh' },
        after_runs = { prompt = { { { exit = 1 } } } },
      })
      local path = ctx:write_session(
        'first.jsonl',
        { id = 'first', cwd = vim.fn.getcwd() },
        { text_message('user', 1, 'hi') }
      )
      observation:submit({ text = 'die' }):wait()
      wait_for(function()
        return not process.get().process:is_running()
      end)
      observation:submit({ text = 'again' }):wait()
      local switches = ctx:received_of('switch_session')
      assert.equals(1, #switches)
      assert.equals(vim.fs.normalize(path), switches[1].sessionPath)
      assert.equals('again', ctx:received_of('prompt')[2].message)
    end)
  end)
end)
