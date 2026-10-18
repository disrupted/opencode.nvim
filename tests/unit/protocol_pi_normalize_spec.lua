local normalize = require('opencode.protocols.pi.normalize')

describe('pi normalize', function()
  local call = { type = 'toolCall', id = 'c1', name = 'bash', arguments = { command = 'ls', description = 'list' } }
  local history = {
    { role = 'user', timestamp = 1, content = { { type = 'text', text = 'go' } } },
    { role = 'assistant', timestamp = 2, content = { { type = 'thinking', thinking = 'hm' }, call } },
    {
      role = 'toolResult',
      timestamp = 3,
      toolCallId = 'c1',
      toolName = 'bash',
      content = { { type = 'text', text = 'out' } },
    },
  }

  it('merges a tool result into its call and keeps reasoning separate', function()
    local entries = normalize.entries(history, 's')
    assert.equals(2, #entries)
    local content = entries[2].content
    assert.equals('reasoning', content[1].kind)
    assert.equals('tool', content[2].kind)
    assert.equals('completed', content[2].state)
    assert.equals('out', content[2].result[1].text)
    assert.equals('ls', content[2].command)
  end)

  it('marks an erroring result', function()
    local failing = vim.deepcopy(history)
    failing[3].isError = true
    local part = normalize.entries(failing, 's')[2].content[2]
    assert.equals('error', part.state)
    assert.equals('out', part.error.message)
  end)

  it('keeps ids stable between history and a rebuilt entry', function()
    local first = normalize.entries(history, 's')[2]
    local rebuilt = normalize.entry(history[2], 's', 2)
    assert.equals(first.id, rebuilt.id)
    assert.equals(first.content[2].id, rebuilt.content[2].id)
  end)

  it('carries merged results across a streamed rebuild', function()
    local first = normalize.entries(history, 's')[2]
    local rebuilt = normalize.entry(history[2], 's', 2)
    normalize.carry_tool_state(rebuilt, first)
    assert.equals('out', rebuilt.content[2].result[1].text)
  end)

  it('shows an orphan tool result as its own entry', function()
    local entries = normalize.entries({ history[3] }, 's')
    assert.equals('assistant', entries[1].kind)
    assert.equals('out', entries[1].content[1].result[1].text)
  end)

  it('applies live tool execution events', function()
    local part = normalize.entry(history[2], 's', 2).content[2]
    normalize.apply_tool_execution(part, { type = 'tool_execution_start' })
    assert.equals('running', part.state)
    normalize.apply_tool_execution(part, {
      type = 'tool_execution_end',
      result = { content = { { type = 'text', text = 'done' } } },
    })
    assert.equals('completed', part.state)
    assert.equals('done', part.result[1].text)
  end)
end)
