local fake_pi = require('tests.mocks.fake_pi_support')
local config = require('opencode.config')
local config_file = require('opencode.config_file')
local base_picker = require('opencode.ui.base_picker')
local model_picker = require('opencode.model_picker')
local variant_picker = require('opencode.variant_picker')
local model_state = require('opencode.model_state')
local state = require('opencode.state')
local stub = require('luassert.stub')

describe('pi backend with the shared model and variant pickers', function()
  local ctx, saved_backend, picked

  before_each(function()
    ctx = fake_pi.start({
      state = { sessionId = 's', model = { id = 'sonnet', provider = 'anthropic', reasoning = true } },
      models = {
        { id = 'sonnet', name = 'Sonnet', provider = 'anthropic', reasoning = true },
        { id = 'opus', name = 'Opus', provider = 'anthropic', reasoning = true },
        { id = 'gpt', name = 'GPT', provider = 'openai', reasoning = false },
      },
      levels = { ['anthropic/sonnet'] = { 'off', 'low', 'high', 'max' } },
    })
    saved_backend = config.values.backend
    config.values.backend = 'pi'
    state.jobs.clear_server()
    config_file.providers_promise = nil
    -- Connecting lazily mid-test would reset the provider cache the pickers rely on.
    require('opencode.server_job').ensure_server():wait()
    stub(model_state, 'load').returns({ favorite = {}, recent = {}, variant = {} })
    picked = nil
    stub(base_picker, 'pick').invokes(function(opts)
      picked = opts
    end)
  end)

  after_each(function()
    base_picker.pick:revert()
    model_state.load:revert()
    local server = state.opencode_server
    if server then
      server:close()
    end
    state.jobs.clear_server()
    config.values.backend = saved_backend
    ctx:stop()
  end)

  local function names(items)
    return vim.tbl_map(function(item)
      return item.provider .. '/' .. item.model
    end, items)
  end

  it('lists the models pi reports', function()
    model_picker.select(function() end):wait()
    assert.same({ 'anthropic/opus', 'anthropic/sonnet', 'openai/gpt' }, names(picked.items))
  end)

  it('offers thinking levels as variants of a reasoning model', function()
    state.model.set_model('anthropic/sonnet')
    variant_picker.select(function() end):wait()
    local variants = vim.tbl_map(function(item)
      return item.name
    end, picked.items)
    assert.equals('default', variants[1])
    assert.same({ 'high', 'low', 'max', 'off' }, vim.fn.sort({ unpack(variants, 2) }))
  end)

  local function variant_names()
    picked = nil
    variant_picker.select(function() end):wait()
    if not picked then
      return nil
    end
    local names = vim.tbl_map(function(item)
      return item.name
    end, picked.items)
    assert.equals('default', table.remove(names, 1))
    return vim.fn.sort(names)
  end

  local function switch_pi_to(provider, id)
    local connection = state.opencode_server
    connection.operations.set_session_model(connection, 's', { providerID = provider, id = id }):wait()
  end

  it('refreshes the variants when the model changes', function()
    state.model.set_model('anthropic/opus')
    assert.same({ 'high', 'low', 'medium', 'minimal', 'off' }, variant_names())
    switch_pi_to('anthropic', 'opus')
    assert.same({ 'high', 'low', 'medium', 'minimal', 'off', 'xhigh' }, variant_names())
    switch_pi_to('anthropic', 'sonnet')
    state.model.set_model('anthropic/sonnet')
    assert.same({ 'high', 'low', 'max', 'off' }, variant_names())
  end)

  it('offers no variants after switching to a non-reasoning model', function()
    switch_pi_to('openai', 'gpt')
    state.model.set_model('openai/gpt')
    assert.is_nil(variant_names())
  end)

  it('does not offer variants for a model without reasoning', function()
    state.model.set_model('openai/gpt')
    variant_picker.select(function() end):wait()
    assert.is_nil(picked)
  end)
end)
