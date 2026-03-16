package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local mock_cjson_safe = require("helpers.mock_cjson_safe")
mock_cjson_safe.install()

local gherkin  = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

-- Minimal JSON decoder for simple flat objects (used by JWT claim extraction)
local function _simple_json_decode(s)
  if type(s) ~= "string" then return nil end
  local result = {}
  -- Extract string values: "key":"value"
  for key, val in s:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
    result[key] = val
  end
  -- Extract numeric values: "key":123
  for key, val in s:gmatch('"([^"]+)"%s*:%s*(%-?%d+%.?%d*)') do
    if result[key] == nil then
      result[key] = tonumber(val)
    end
  end
  local count = 0
  for _ in pairs(result) do count = count + 1 end
  if count > 0 then return result end
  return nil
end

-- Provide a utils stub that works with mock_ngx (base64url_decode uses ngx.decode_base64)
local utils_stub = {
  get_json = function()
    -- Use a minimal decoder that can handle JWT claims like {"sub":"user123"}
    return { decode = _simple_json_decode }
  end,
  base64url_decode = function(s)
    if type(s) ~= "string" then return nil end
    local b64 = s:gsub("-", "+"):gsub("_", "/")
    local pad = #b64 % 4
    if pad == 2 then b64 = b64 .. "==" elseif pad == 3 then b64 = b64 .. "=" end
    if ngx and ngx.decode_base64 then
      return ngx.decode_base64(b64)
    end
    return nil
  end,
}
package.loaded["fairvisor.utils"] = utils_stub
package.loaded["fairvisor.wrapper"] = nil
local wrapper = require("fairvisor.wrapper")

local runner = gherkin.new({ describe = describe, context = context, it = it })

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- eyJzdWIiOiJ1c2VyMTIzIn0 is base64url({"sub":"user123"})
-- eyJhbGciOiJub25lIn0     is base64url({"alg":"none"})
-- Full JWT (alg:none, unsigned): eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyMTIzIn0.
local VALID_JWT  = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyMTIzIn0."

local _OPENAI_TERMINATION =
  'data: {"choices":[{"delta":{},"finish_reason":"length","index":0}]}\n\n'
  .. 'data: [DONE]\n\n'

-- ---------------------------------------------------------------------------
-- Step definitions
-- ---------------------------------------------------------------------------

runner:given("^the nginx mock is set up$", function(_ctx)
  mock_ngx.setup_ngx()
end)

runner:given("^a composite bearer header \"(.-)\"$", function(ctx, header)
  ctx.auth_header = header
end)

runner:given("^an auth header \"(.-)\"$", function(ctx, header)
  ctx.auth_header = header
end)

runner:given("^an auth header with empty key$", function(ctx)
  ctx.auth_header = "Bearer " .. VALID_JWT .. ":"
end)

runner:given("^a nil auth header$", function(ctx)
  ctx.auth_header = nil
end)

runner:when("^parse_composite_bearer is called$", function(ctx)
  ctx.parsed, ctx.parse_err = wrapper.parse_composite_bearer(ctx.auth_header)
end)

runner:then_("^parsing succeeds$", function(ctx)
  assert.is_not_nil(ctx.parsed,
    "expected parse to succeed but got err: " .. tostring(ctx.parse_err))
end)

runner:then_("^the upstream_key is \"(.-)\"$", function(ctx, key)
  assert.is_not_nil(ctx.parsed)
  assert.equals(key, ctx.parsed.upstream_key)
end)

runner:then_("^JWT claims have sub \"(.-)\"$", function(ctx, sub)
  assert.is_not_nil(ctx.parsed)
  assert.is_not_nil(ctx.parsed.claims)
  assert.equals(sub, ctx.parsed.claims.sub)
end)

runner:then_("^parsing fails with reason \"(.-)\"$", function(ctx, reason)
  assert.is_nil(ctx.parsed)
  assert.equals(reason, ctx.parse_err)
end)

-- ---------------------------------------------------------------------------
-- Provider routing
-- ---------------------------------------------------------------------------

runner:when("^I call get_provider for path \"(.-)\"$", function(ctx, path)
  ctx.provider = wrapper.get_provider(path)
end)

runner:then_("^provider prefix is \"(.-)\"$", function(ctx, prefix)
  assert.is_not_nil(ctx.provider,
    "expected provider but got nil")
  assert.equals(prefix, ctx.provider.prefix)
end)

runner:then_("^provider upstream is \"(.-)\"$", function(ctx, upstream)
  assert.is_not_nil(ctx.provider)
  assert.equals(upstream, ctx.provider.upstream)
end)

runner:then_("^provider auth_header is \"(.-)\"$", function(ctx, auth_header)
  assert.is_not_nil(ctx.provider)
  assert.equals(auth_header, ctx.provider.auth_header)
end)

runner:then_("^provider auth_header is nil$", function(ctx)
  assert.is_not_nil(ctx.provider)
  assert.is_nil(ctx.provider.auth_header)
end)

runner:then_("^provider is nil$", function(ctx)
  assert.is_nil(ctx.provider)
end)

-- ---------------------------------------------------------------------------
-- Pre-flight error bodies
-- ---------------------------------------------------------------------------

runner:given("^provider error_format is \"(.-)\"$", function(ctx, fmt)
  ctx.provider = { error_format = fmt, cutoff_format = fmt }
end)

runner:when("^I call preflight_error_body with reason \"(.-)\"$", function(ctx, reason)
  ctx.error_body = wrapper.preflight_error_body(ctx.provider, reason, nil)
end)

runner:then_("^error body contains \"(.-)\"$", function(ctx, pattern)
  assert.is_not_nil(ctx.error_body)
  assert.truthy(ctx.error_body:find(pattern, 1, true),
    "expected error body to contain '" .. pattern .. "' but got: " .. ctx.error_body)
end)

runner:then_("^error body does not contain \"(.-)\"$", function(ctx, pattern)
  assert.is_not_nil(ctx.error_body)
  assert.falsy(ctx.error_body:find(pattern, 1, true),
    "expected error body NOT to contain '" .. pattern .. "'")
end)

-- ---------------------------------------------------------------------------
-- Streaming cutoff formats
-- ---------------------------------------------------------------------------

runner:given("^provider cutoff_format is \"(.-)\"$", function(ctx, fmt)
  ctx.provider = { error_format = fmt, cutoff_format = fmt }
end)

runner:when("^I call streaming_cutoff_for_provider$", function(ctx)
  ctx.cutoff = wrapper.streaming_cutoff_for_provider(ctx.provider)
end)

runner:then_("^cutoff contains \"(.-)\"$", function(ctx, pattern)
  assert.is_not_nil(ctx.cutoff)
  assert.truthy(ctx.cutoff:find(pattern, 1, true),
    "expected cutoff to contain '" .. pattern .. "'")
end)

runner:then_("^cutoff does not contain \"(.-)\"$", function(ctx, pattern)
  assert.is_not_nil(ctx.cutoff)
  assert.falsy(ctx.cutoff:find(pattern, 1, true),
    "expected cutoff NOT to contain '" .. pattern .. "'")
end)

-- ---------------------------------------------------------------------------
-- replace_openai_cutoff
-- ---------------------------------------------------------------------------

runner:given("^an SSE output ending with OpenAI finish_reason and DONE$", function(ctx)
  ctx.sse_input = 'data: {"choices":[{"delta":{"content":"hello"}}]}\n\n'
    .. _OPENAI_TERMINATION
end)

runner:given("^an SSE output with no DONE marker$", function(ctx)
  ctx.sse_input = 'data: {"choices":[{"delta":{"content":"hello"}}]}\n\n'
end)

runner:when("^replace_openai_cutoff is called with format \"(.-)\"$", function(ctx, fmt)
  ctx.output = wrapper.replace_openai_cutoff(ctx.sse_input, fmt)
end)

runner:then_("^output contains \"(.-)\"$", function(ctx, pattern)
  assert.is_not_nil(ctx.output)
  assert.truthy(ctx.output:find(pattern, 1, true),
    "expected output to contain '" .. pattern .. "'")
end)

runner:then_("^output does not contain \"(.-)\"$", function(ctx, pattern)
  assert.is_not_nil(ctx.output)
  assert.falsy(ctx.output:find(pattern, 1, true),
    "expected output NOT to contain '" .. pattern .. "'")
end)

runner:then_("^output is returned unchanged$", function(ctx)
  assert.equals(ctx.sse_input, ctx.output)
end)

-- ---------------------------------------------------------------------------
-- Policy header descriptor collection
-- ---------------------------------------------------------------------------

runner:given("^a bundle with limit_key \"(.-)\"$", function(ctx, limit_key)
  ctx.bundle = {
    policies = {
      {
        spec = {
          rules = {
            {
              name       = "test-rule",
              limit_keys = { limit_key },
            },
          },
        },
      },
    },
  }
end)

runner:given("^a bundle with match key \"(.-)\"$", function(ctx, match_key)
  ctx.bundle = {
    policies = {
      {
        spec = {
          rules = {
            {
              name       = "test-rule",
              match      = { [match_key] = "some-value" },
              limit_keys = { "jwt:sub" },
            },
          },
        },
      },
    },
  }
end)

runner:given("^a nil bundle$", function(ctx)
  ctx.bundle = nil
end)

runner:when("^I call collect_policy_header_descriptors$", function(ctx)
  ctx.descriptors = wrapper.collect_policy_header_descriptors(ctx.bundle)
end)

runner:then_("^header descriptors contain \"(.-)\"$", function(ctx, name)
  assert.is_not_nil(ctx.descriptors)
  assert.truthy(ctx.descriptors[name],
    "expected header descriptors to contain '" .. name .. "'")
end)

runner:then_("^header descriptors is empty$", function(ctx)
  assert.is_not_nil(ctx.descriptors)
  local count = 0
  for _ in pairs(ctx.descriptors) do count = count + 1 end
  assert.equals(0, count)
end)

-- ---------------------------------------------------------------------------
-- Response auth header sanitization
-- ---------------------------------------------------------------------------

runner:given("^wrapper response headers contain auth%-related headers$", function(_ctx)
  ngx.header = {
    ["Authorization"] = "Bearer should-not-leak",
    ["x-api-key"] = "anthropic-secret",
    ["x-goog-api-key"] = "gemini-secret",
    ["Content-Type"] = "application/json",
  }
end)

runner:when("^I call strip_response_auth_headers$", function(ctx)
  wrapper.strip_response_auth_headers()
  ctx.response_headers = ngx.header
end)

runner:then_("^response header \"(.-)\" is nil$", function(ctx, name)
  assert.is_not_nil(ctx.response_headers)
  assert.is_nil(ctx.response_headers[name])
end)

runner:then_("^response header \"(.-)\" is \"(.-)\"$", function(ctx, name, value)
  assert.is_not_nil(ctx.response_headers)
  assert.equals(value, ctx.response_headers[name])
end)

-- ---------------------------------------------------------------------------
-- access_handler setup helpers
-- ---------------------------------------------------------------------------

local function _setup_access_handler_ngx(ctx)
  mock_ngx.setup_ngx()
  ctx.exit_code  = nil
  ctx.request_headers = {}
  -- Reset wrapper deps (no rule_engine by default)
  wrapper.init({ health = nil, rule_engine = nil, bundle_loader = nil })
  -- Extend mock with access_handler-needed APIs
  ngx.req.get_headers  = function() return ctx.request_headers end
  ngx.req.clear_header = function(_n) end
  ngx.req.set_header   = function(_n, _v) end
  ngx.header = {}
  ngx.ctx    = {}
  ngx.var.uri                  = "/openai/v1/chat/completions"
  ngx.var.args                 = ""
  ngx.var.wrapper_upstream_url = ""
  ngx.var.request_method       = "POST"
  ngx.var.host                 = "localhost"
  ngx.var.remote_addr          = "127.0.0.1"
  ngx.status = 200
  ngx.print  = function(_body) end
  ngx.exit   = function(code) ctx.exit_code = code end
end

runner:given("^the nginx mock is set up for access_handler$", function(ctx)
  _setup_access_handler_ngx(ctx)
end)

runner:given("^request path is \"(.-)\"$", function(ctx, path)
  ngx.var.uri = path
end)

runner:given("^request auth header is \"(.-)\"$", function(ctx, header)
  ctx.request_headers["Authorization"] = header
  ngx.req.get_headers = function() return ctx.request_headers end
end)

runner:given("^mock rule_engine returns action \"(.-)\"$", function(ctx, action)
  local mock_re = {
    evaluate = function(self, _req_ctx, _bundle)
      return { action = action, reason = "rate_limit_exceeded" }
    end,
  }
  local mock_bl = {
    get_current = function() return { policies = {} } end,
  }
  wrapper.init({ rule_engine = mock_re, bundle_loader = mock_bl })
end)

runner:when("^access_handler is called$", function(ctx)
  ctx.ah_ok, ctx.ah_err = pcall(wrapper.access_handler)
end)

runner:then_(("^response exit code is (%d+)$"), function(ctx, code_str)
  assert.equals(tonumber(code_str), ctx.exit_code,
    "expected exit code " .. code_str .. " but got " .. tostring(ctx.exit_code))
end)

runner:then_(("^upstream url contains \"(.-)\"$"), function(ctx, pattern)
  local url = ngx.var.wrapper_upstream_url
  assert.truthy(url and url:find(pattern, 1, true),
    "expected upstream_url to contain '" .. pattern .. "' but got: " .. tostring(url))
end)

runner:then_(("^ngx exit was not called$"), function(ctx)
  assert.is_nil(ctx.exit_code,
    "expected ngx.exit not to be called but got code: " .. tostring(ctx.exit_code))
end)

-- ---------------------------------------------------------------------------
-- wrapper init
-- ---------------------------------------------------------------------------

runner:when("^I call wrapper init with valid deps$", function(ctx)
  ctx.init_result, ctx.init_err = wrapper.init({
    health = nil, rule_engine = nil, bundle_loader = nil,
  })
end)

runner:when("^I call wrapper init with nil$", function(ctx)
  ctx.init_result, ctx.init_err = wrapper.init(nil)
end)

runner:then_("^init result is true$", function(ctx)
  assert.is_true(ctx.init_result)
end)

runner:then_("^init result is nil$", function(ctx)
  assert.is_nil(ctx.init_result)
end)

-- ---------------------------------------------------------------------------
-- Run scenarios from feature file
-- ---------------------------------------------------------------------------
runner:feature_file_relative("features/wrapper.feature")
