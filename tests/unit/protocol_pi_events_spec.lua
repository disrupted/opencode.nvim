local fake_pi = require('tests.mocks.fake_pi_support')
local adapter = require('opencode.protocols.pi.connection')

describe('pi run events over a fake pi process', function()
  local ctx, connection, observation, unwatch

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

  describe('run notices', function()
    local function run(events)
      -- The admission is registered once the prompt response lands; events racing it would be missed.
      return { prompt = vim.list_extend({ { sleep = 40 }, ev({ type = 'agent_start' }) }, events) }
    end

    it('shows a scheduled retry and returns to running when it starts', function()
      open({
        state = { sessionId = 's' },
        after = run({
          ev({ type = 'auto_retry_start', attempt = 2, maxAttempts = 3, delayMs = 4000, errorMessage = 'overloaded' }),
        }),
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return observation:read().execution.activity == 'retrying'
      end)
      local retry = observation:read().execution.retry
      assert.equals(2, retry.attempt)
      assert.equals('overloaded', retry.message)
      assert.is_true(retry.scheduled_at > vim.uv.now())
    end)

    it('treats agent_end with willRetry as retrying, not finished', function()
      open({ state = { sessionId = 's' }, after = run({ ev({ type = 'agent_end', willRetry = true }) }) })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return observation:read().execution.activity == 'retrying'
      end)
    end)

    it('resumes running when a retry succeeds', function()
      open({
        state = { sessionId = 's' },
        after = run({
          ev({ type = 'auto_retry_start', attempt = 1, delayMs = 1 }),
          ev({ type = 'auto_retry_end', success = true, attempt = 1 }),
        }),
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return observation:read().execution.activity == 'running' and observation:read().execution.retry == nil
      end)
    end)

    it('fails the run with a notice when retries are exhausted', function()
      open({
        state = { sessionId = 's' },
        after = run({
          ev({ type = 'auto_retry_start', attempt = 3, delayMs = 1 }),
          ev({ type = 'auto_retry_end', success = false, attempt = 3, finalError = 'still overloaded' }),
          ev({ type = 'agent_settled' }),
        }),
      })
      local outcome = observation:submit({ text = 'go' }):wait().completion:wait()
      assert.equals('failed', outcome.outcome)
      assert.matches('still overloaded', outcome.error.message)
      assert.matches('Pi retry failed: still overloaded', last_text())
    end)

    it('reports a failed compaction and a successful one with its summary', function()
      open({
        state = { sessionId = 's' },
        after = run({
          ev({ type = 'compaction_start', reason = 'threshold' }),
          ev({ type = 'compaction_end', reason = 'threshold', errorMessage = 'too big' }),
          ev({ type = 'compaction_end', reason = 'threshold', result = { summary = 'short' } }),
        }),
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return #entries() >= 2
      end)
      local texts = vim.tbl_map(function(entry)
        return entry.content[1].text
      end, entries())
      assert.is_truthy(vim.tbl_contains(texts, 'Compaction failed: too big'))
      assert.is_truthy(vim.tbl_contains(texts, 'Compaction complete\n\nshort'))
    end)

    it('runs a manual compaction as an activity and reloads history afterwards', function()
      open({
        state = { sessionId = 's' },
        messages = { user(1, 'kept') },
        after = {
          compact = {
            ev({ type = 'compaction_start', reason = 'manual' }),
            ev({ type = 'compaction_end', reason = 'manual', result = { summary = 'sum' } }),
          },
        },
      })
      ops().summarize_session(connection, 's', location()):wait()
      wait_for(function()
        return observation:read().execution.last_outcome == 'succeeded'
      end)
      assert.equals('idle', observation:read().execution.activity)
      wait_for(function()
        return #ctx:received_of('get_messages') >= 2
      end, 'history was not reloaded after compaction')
    end)

    it('keeps a notice across a history reload', function()
      open({
        state = { sessionId = 's' },
        messages = { user(1, 'kept') },
        after = { compact = { ev({ type = 'compaction_end', reason = 'manual', result = { summary = 'sum' } }) } },
      })
      ops().summarize_session(connection, 's', location()):wait()
      wait_for(function()
        return #ctx:received_of('get_messages') >= 2 and observation:read().sync.messages.state == 'current'
      end)
      assert.matches('Compaction complete', last_text())
    end)

    it('surfaces an extension error', function()
      open({
        state = { sessionId = 's' },
        after = run({ ev({ type = 'extension_error', extensionPath = '/ext/a.ts', event = 'x', error = 'boom' }) }),
      })
      observation:submit({ text = 'go' }):wait()
      wait_for(function()
        return #entries() >= 1
      end)
      assert.matches('Pi extension error %(/ext/a.ts%): boom', last_text())
    end)
  end)
end)
