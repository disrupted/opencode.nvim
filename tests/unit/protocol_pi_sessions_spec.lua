local fake_pi = require('tests.mocks.fake_pi_support')
local sessions = require('opencode.protocols.pi.sessions')
local operations = require('opencode.protocols.pi.operations')

describe('pi sessions', function()
  local ctx

  ---@param path string
  ---@param seconds integer
  local function touch(path, seconds)
    assert(vim.uv.fs_utime(path, seconds, seconds))
  end

  local function user(text)
    return { role = 'user', timestamp = 1, content = { { type = 'text', text = text } } }
  end

  before_each(function()
    ctx = fake_pi.start({})
  end)

  after_each(function()
    ctx:stop()
  end)

  describe('lookup', function()
    it('finds a session by the id in its header, not by file name', function()
      ctx:write_session('2026-01-01_unrelated-name.jsonl', { id = 'real-id', cwd = '/w' }, { user('hello') })
      local found = sessions.find('real-id')
      assert.is_truthy(found)
      assert.equals('real-id', found.id)
      assert.is_nil(sessions.find('2026-01-01_unrelated-name'))
    end)

    it('returns nil for an unknown id and for an empty or missing root', function()
      assert.is_nil(sessions.find('nope'))
      vim.fn.delete(ctx.session_dir, 'rf')
      assert.same({}, sessions.list())
    end)

    it('finds sessions at the root and in per-workspace subdirectories', function()
      ctx:write_session('root.jsonl', { id = 'at-root', cwd = '/a' })
      ctx:write_session('--w--/nested.jsonl', { id = 'nested', cwd = '/w' })
      assert.is_truthy(sessions.find('at-root'))
      assert.is_truthy(sessions.find('nested'))
    end)

    it('follows a renamed file to its new path', function()
      local old = ctx:write_session('old-name.jsonl', { id = 'moved', cwd = '/w' })
      local new = vim.fs.joinpath(ctx.session_dir, 'new-name.jsonl')
      assert(vim.uv.fs_rename(old, new))
      local found = sessions.find('moved')
      assert.equals(vim.fs.normalize(new), found.path)
      assert.equals(1, #sessions.list())
    end)

    it('skips files without a session header and tolerates broken lines', function()
      local path = vim.fs.joinpath(ctx.session_dir, 'broken.jsonl')
      vim.fn.writefile({
        '{not json',
        vim.json.encode({ type = 'session', id = 'survivor', cwd = '/w' }),
        '',
        vim.json.encode({ type = 'message', message = user('still readable') }),
      }, path)
      vim.fn.writefile(
        { vim.json.encode({ type = 'message', message = user('orphan') }) },
        vim.fs.joinpath(ctx.session_dir, 'headerless.jsonl')
      )
      vim.fn.writefile({}, vim.fs.joinpath(ctx.session_dir, 'empty.jsonl'))
      local listed = sessions.list()
      assert.equals(1, #listed)
      assert.equals('survivor', listed[1].id)
      assert.equals('still readable', listed[1].title)
    end)

    it('ignores non-jsonl files', function()
      vim.fn.writefile(
        { vim.json.encode({ type = 'session', id = 'x', cwd = '/w' }) },
        vim.fs.joinpath(ctx.session_dir, 'x.txt')
      )
      assert.same({}, sessions.list())
    end)
  end)

  describe('duplicates', function()
    it('collapses a forked file repeating its parent id to the most recently updated one', function()
      local parent = ctx:write_session('parent.jsonl', { id = 'shared', cwd = '/w' }, { user('parent') })
      local fork = ctx:write_session('fork.jsonl', { id = 'shared', cwd = '/w' }, { user('fork') })
      touch(parent, 1000)
      touch(fork, 2000)
      local listed = sessions.list()
      assert.equals(1, #listed)
      assert.equals(vim.fs.normalize(fork), listed[1].path)
      assert.equals('fork', sessions.find('shared').title)

      touch(parent, 3000)
      assert.equals(vim.fs.normalize(parent), sessions.find('shared').path)
    end)

    it('keeps distinct ids side by side, newest first', function()
      local a = ctx:write_session('a.jsonl', { id = 'a', cwd = '/w' })
      local b = ctx:write_session('b.jsonl', { id = 'b', cwd = '/w' })
      local c = ctx:write_session('c.jsonl', { id = 'c', cwd = '/w' })
      touch(a, 3000)
      touch(b, 1000)
      touch(c, 2000)
      assert.same(
        { 'a', 'c', 'b' },
        vim.tbl_map(function(s)
          return s.id
        end, sessions.list())
      )
    end)
  end)

  describe('titles', function()
    it('prefers the latest session_info name over the header name and first prompt', function()
      local path = ctx:write_session(
        't.jsonl',
        { id = 't', cwd = '/w', name = 'header name' },
        { user('first prompt') }
      )
      assert.equals('header name', sessions.find('t').title)
      local lines = vim.fn.readfile(path)
      lines[#lines + 1] = vim.json.encode({ type = 'session_info', name = 'first rename' })
      lines[#lines + 1] = vim.json.encode({ type = 'session_info', name = 'second rename' })
      vim.fn.writefile(lines, path)
      assert.equals('second rename', sessions.find('t').title)
    end)

    it('falls back to the first user prompt, then the id', function()
      ctx:write_session('p.jsonl', { id = 'p', cwd = '/w' }, {
        { role = 'assistant', content = { { type = 'text', text = 'not me' } } },
        user('  spaced\n  out   prompt '),
      })
      ctx:write_session('i.jsonl', { id = 'bare-id', cwd = '/w' })
      assert.equals('spaced out prompt', sessions.find('p').title)
      assert.equals('bare-id', sessions.find('bare-id').title)
    end)

    it('reads a first prompt stored as a plain string', function()
      ctx:write_session('s.jsonl', { id = 's', cwd = '/w' }, { { role = 'user', content = 'plain text' } })
      assert.equals('plain text', sessions.find('s').title)
    end)

    it('truncates long titles with an ellipsis', function()
      ctx:write_session('l.jsonl', { id = 'l', cwd = '/w' }, { user(('x'):rep(200)) })
      local title = sessions.find('l').title
      assert.equals(70, vim.fn.strchars(title))
      assert.equals('…', vim.fn.strcharpart(title, 69, 1))
    end)
  end)

  describe('workspace filtering', function()
    before_each(function()
      ctx:write_session('one.jsonl', { id = 'in-a-1', cwd = '/work/a' })
      ctx:write_session('two.jsonl', { id = 'in-a-2', cwd = '/work/a' })
      ctx:write_session('three.jsonl', { id = 'in-b', cwd = '/work/b' })
    end)

    local function ids(result)
      local out = vim.tbl_map(function(s)
        return s.id
      end, result)
      table.sort(out)
      return out
    end

    it('records the header cwd as the session location', function()
      assert.equals('/work/b', sessions.find('in-b').location.directory)
    end)

    it('lists only sessions of the requested directory', function()
      local project = operations.list_sessions_project(nil, { directory = '/work/a' }):wait()
      assert.same({ 'in-a-1', 'in-a-2' }, ids(project))
      local paged = operations.list_sessions(nil, { directory = '/work/b' }):wait()
      assert.same({ 'in-b' }, ids(paged.data))
    end)

    it('lists everything globally and nothing for an unknown directory', function()
      assert.equals(3, #operations.list_sessions_global():wait())
      assert.same({}, operations.list_sessions_project(nil, { directory = '/elsewhere' }):wait())
    end)

    it('does not match a directory that is only a prefix', function()
      assert.same({}, operations.list_sessions_project(nil, { directory = '/work' }):wait())
    end)
  end)

  describe('messages', function()
    it('reads message records only, falling back to the entry timestamp', function()
      local path = vim.fs.joinpath(ctx.session_dir, 'm.jsonl')
      vim.fn.writefile({
        vim.json.encode({ type = 'session', id = 'm', cwd = '/w' }),
        vim.json.encode({ type = 'session_info', name = 'n' }),
        vim.json.encode({
          type = 'message',
          timestamp = '2026-01-01T00:00:00Z',
          message = { role = 'user', content = 'a' },
        }),
        vim.json.encode({ type = 'message', message = { role = 'assistant', timestamp = 5, content = {} } }),
      }, path)
      local messages = sessions.read_messages(path)
      assert.equals(2, #messages)
      assert.equals('2026-01-01T00:00:00Z', messages[1].timestamp)
      assert.equals(5, messages[2].timestamp)
    end)
  end)

  describe('ordering', function()
    local function fact(id, updated, path)
      return { id = id, time = { updated = updated, created = 0 }, path = path }
    end

    it('breaks equal timestamps by id, then path', function()
      assert.is_true(sessions.is_newer(fact('a', 6, 'x'), fact('b', 5, 'x')))
      assert.is_true(sessions.is_newer(fact('a', 5, 'x'), fact('b', 5, 'x')))
      assert.is_false(sessions.is_newer(fact('b', 5, 'x'), fact('a', 5, 'x')))
      assert.is_true(sessions.is_newer(fact('a', 5, 'x'), fact('a', 5, 'y')))
      assert.is_false(sessions.is_newer(fact('a', 5, 'x'), fact('a', 5, 'x')))
    end)

    it('lists sessions with identical mtimes in a stable order', function()
      for _, name in ipairs({ 'c', 'a', 'b' }) do
        local path = ctx:write_session(name .. '.jsonl', { id = name, cwd = '/w' }, { user(name) })
        touch(path, 1000)
      end
      local ids = vim.tbl_map(function(session)
        return session.id
      end, sessions.list())
      assert.same({ 'a', 'b', 'c' }, ids)
    end)
  end)
end)
