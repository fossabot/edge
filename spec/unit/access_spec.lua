package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local mock_ngx = require("helpers.mock_ngx")
local gherkin  = require("helpers.gherkin")

-- ---------------------------------------------------------------------------
-- Call tracking (reset per scenario)
-- ---------------------------------------------------------------------------
local _calls = {}

-- ---------------------------------------------------------------------------
-- Lightweight mock — mimics wrapper.get_provider prefix logic without
-- loading the real module (which pulls in ngx at module init time).
-- ---------------------------------------------------------------------------
local _PROVIDER_PREFIXES = {
  "/gemini-compat", "/openai", "/anthropic", "/gemini",
  "/grok", "/groq", "/mistral", "/deepseek", "/perplexity",
  "/together", "/fireworks", "/cerebras", "/ollama",
}

local _wrapper_mock = {
  get_provider = function(path)
    if type(path) ~= "string" then return nil end
    for _, prefix in ipairs(_PROVIDER_PREFIXES) do
      if path:sub(1, #prefix) == prefix then
        local next_char = path:sub(#prefix + 1, #prefix + 1)
        if next_char == "/" or next_char == "" then
          return { prefix = prefix }
        end
      end
    end
    return nil
  end,
  access_handler = function()
    _calls.wrapper = (_calls.wrapper or 0) + 1
  end,
}

local _decision_mock = {
  access_handler = function()
    _calls.decision_api = (_calls.decision_api or 0) + 1
  end,
}

-- Pre-populate package.loaded so access.lua picks up mocks via require()
package.loaded["fairvisor.wrapper"]      = _wrapper_mock
package.loaded["fairvisor.decision_api"] = _decision_mock

-- ---------------------------------------------------------------------------
-- Step definitions
-- ---------------------------------------------------------------------------
local runner = gherkin.new({ describe = describe, context = context, it = it })

runner:given("^nginx mode is \"(.-)\" and uri is \"(.-)\"$", function(ctx, mode, uri)
  mock_ngx.setup_ngx()
  ngx.var.fairvisor_mode = mode
  ngx.var.uri            = uri
  _calls = {}
end)

runner:when("^the access dispatcher runs$", function(ctx)
  local chunk, err = loadfile("src/nginx/access.lua")
  assert.is_not_nil(chunk, "loadfile(src/nginx/access.lua) failed: " .. tostring(err))
  chunk()
end)

runner:then_("^wrapper access_handler is called$", function(ctx)
  assert.is_truthy((_calls.wrapper or 0) > 0,
    "expected wrapper.access_handler() to be called but it was not")
end)

runner:then_("^decision_api access_handler is called$", function(ctx)
  assert.is_truthy((_calls.decision_api or 0) > 0,
    "expected decision_api.access_handler() to be called but it was not")
end)

runner:then_("^neither handler is called$", function(ctx)
  assert.equals(0, _calls.wrapper or 0,
    "wrapper.access_handler should not be called")
  assert.equals(0, _calls.decision_api or 0,
    "decision_api.access_handler should not be called")
end)

-- ---------------------------------------------------------------------------
-- Run scenarios from feature file
-- ---------------------------------------------------------------------------
runner:feature_file_relative("features/access.feature")
