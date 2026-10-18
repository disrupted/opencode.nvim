local catalog = require('opencode.protocols.pi.catalog')

describe('pi catalog', function()
  local models = {
    { id = 'sonnet', name = 'Sonnet', provider = 'anthropic', reasoning = true, contextWindow = 200000 },
    { id = 'gpt', provider = 'openai', reasoning = false },
    { id = 'haiku', name = 'Haiku', provider = 'anthropic' },
  }

  it('groups models under sorted providers and marks the current one as default', function()
    local result = catalog.catalog(models, models[2])
    assert.same({ 'anthropic', 'openai' }, {
      result.providers[1].id,
      result.providers[2].id,
    })
    assert.equals('Sonnet', result.providers[1].models.sonnet.name)
    assert.equals('gpt', result.providers[2].models.gpt.name)
    assert.same({ openai = 'gpt' }, result.default)
  end)

  it('lists only the levels pi reports for the current model, including max', function()
    local result = catalog.catalog(models, models[1], { 'off', 'low', 'max' })
    local sonnet = result.providers[1].models.sonnet
    assert.same({ 'low', 'max', 'off' }, vim.fn.sort(vim.tbl_keys(sonnet.variants)))
    assert.is_nil(sonnet.variants.xhigh)
    assert.equals(200000, sonnet.limit.context)
  end)

  it('does not guess levels for models that are not current', function()
    local result = catalog.catalog(models, models[2], { 'off' })
    local sonnet = result.providers[1].models.sonnet
    assert.is_true(sonnet.reasoning)
    assert.is_nil(sonnet.variants)
    assert.same({}, catalog.catalog(models).default)
  end)

  it('offers no variants when the current model only supports off', function()
    local result = catalog.catalog(models, models[1], { 'off' })
    assert.is_nil(result.providers[1].models.sonnet.variants)
    assert.is_nil(result.providers[1].models.haiku.variants)
  end)

  it('reads the current model and thinking level from pi state', function()
    assert.same(
      { providerID = 'openai', id = 'gpt', variant = 'low' },
      catalog.current_model({ model = models[2], thinkingLevel = 'low' })
    )
    assert.is_nil(catalog.current_model({}))
  end)

  describe('commands', function()
    local commands = {
      { name = 'review', description = 'Review', source = 'prompt', path = '/p/review.md' },
      { name = 'deploy', source = 'extension' },
      { name = 'skill:lint', description = 'Lint', source = 'skill', path = '/s/lint/SKILL.md' },
    }

    it('keeps every command with its source', function()
      local list = catalog.commands(commands)
      assert.equals(3, #list)
      assert.equals('skill', list[3].source)
    end)

    it('strips the skill prefix and makes the invocation the content', function()
      local skills = catalog.skills(commands)
      assert.equals(1, #skills)
      assert.equals('lint', skills[1].name)
      assert.equals('/skill:lint', skills[1].content)
      assert.equals('/s/lint/SKILL.md', skills[1].location)
    end)

    it('leaves skills out of user commands', function()
      local user = catalog.user_commands(commands)
      assert.same({ 'deploy', 'review' }, vim.fn.sort(vim.tbl_keys(user)))
      assert.equals('', user.deploy.description)
    end)
  end)
end)
