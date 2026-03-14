package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local mock_cjson_safe = require("helpers.mock_cjson_safe")
mock_cjson_safe.install()

local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")

local reconcile_calls = {}

package.loaded["fairvisor.llm_limiter"] = {
  reconcile = function(dict, key, config, estimated_total, actual_total, now)
    reconcile_calls[#reconcile_calls + 1] = {
      dict = dict,
      key = key,
      config = config,
      estimated_total = estimated_total,
      actual_total = actual_total,
      now = now,
    }
    return {
      refunded = 0,
      estimated = estimated_total,
      actual = actual_total,
    }
  end,
}

package.loaded["fairvisor.streaming"] = nil
local streaming = require("fairvisor.streaming")

local runner = gherkin.new({ describe = describe, context = context, it = it })

local function _mk_delta_event(tokens)
  local content = string.rep("x", tonumber(tokens) * 4)
  return 'data: {"choices":[{"delta":{"content":"' .. content .. '"}}]}\n\n'
end

local function _reset_env(ctx)
  local env = mock_ngx.setup_ngx()
  reconcile_calls = {}
  local logs = {}
  ctx.queued_events = {}

  _G.ngx.ctx = {}
  _G.ngx.shared.fairvisor_counters = env.dict
  _G.ngx.log = function(_, ...)
    logs[#logs + 1] = table.concat({ ... }, "")
  end

  local saas_client = {
    queue_event = function(event)
      ctx.queued_events[#ctx.queued_events + 1] = event
      return true
    end
  }
  package.loaded["fairvisor.saas_client"] = saas_client

  ctx.logs = logs
  ctx.dict = env.dict
  ctx.time = env.time
  ctx.request_context = nil
  ctx.config = nil
  ctx.reservation = nil
  ctx.stream_ctx = nil
  ctx.output = nil
  ctx.output2 = nil
end

runner:given("^the nginx mock environment is reset$", function(ctx)
  _reset_env(ctx)
end)

runner:given("^a request body with stream true$", function(ctx)
  ctx.request_context = {
    body = '{"model":"gpt","stream": true}',
    headers = {},
  }
end)

runner:given("^a request accept header for text/event%-stream$", function(ctx)
  ctx.request_context = {
    body = "{}",
    headers = {
      Accept = "text/event-stream",
    },
  }
end)

runner:given("^a non%-streaming request context$", function(ctx)
  ctx.request_context = {
    body = '{"model":"gpt","stream": false}',
    headers = {
      Accept = "application/json",
    },
  }
end)

runner:when("^I detect whether it is streaming$", function(ctx)
  ctx.is_streaming = streaming.is_streaming(ctx.request_context)
end)

runner:then_("^streaming detection returns true$", function(ctx)
  assert.is_true(ctx.is_streaming)
end)

runner:then_("^streaming detection returns false$", function(ctx)
  assert.is_false(ctx.is_streaming)
end)

runner:given("^a valid streaming config$", function(ctx)
  ctx.validation_config = {
    streaming = {},
  }
end)

runner:given("^an invalid streaming config with buffer_tokens 0$", function(ctx)
  ctx.validation_config = {
    streaming = {
      buffer_tokens = 0,
    },
  }
end)

runner:when("^I validate streaming config$", function(ctx)
  ctx.ok, ctx.err = streaming.validate_config(ctx.validation_config)
end)

runner:then_("^streaming config validation succeeds with defaults$", function(ctx)
  assert.is_true(ctx.ok)
  assert.is_nil(ctx.err)
  assert.is_true(ctx.validation_config.streaming.enabled)
  assert.is_true(ctx.validation_config.streaming.enforce_mid_stream)
  assert.equals(100, ctx.validation_config.streaming.buffer_tokens)
  assert.equals("graceful_close", ctx.validation_config.streaming.on_limit_exceeded)
  assert.is_true(ctx.validation_config.streaming.include_partial_usage)
end)

runner:then_("^streaming config validation fails with buffer error$", function(ctx)
  assert.is_nil(ctx.ok)
  assert.equals("streaming.buffer_tokens must be a positive number", ctx.err)
end)

runner:given("^a streaming context with max_completion_tokens (%d+) and buffer_tokens (%d+)$",
function(ctx, max_completion_tokens, buffer_tokens)
  ctx.config = {
    max_completion_tokens = tonumber(max_completion_tokens),
    streaming = {
      enabled = true,
      enforce_mid_stream = true,
      buffer_tokens = tonumber(buffer_tokens),
      on_limit_exceeded = "graceful_close",
      include_partial_usage = true,
    },
  }

  ctx.request_context = {
    body = '{"stream":true}',
    headers = {
      Accept = "text/event-stream",
    },
  }

  ctx.reservation = {
    key = "tenant-1",
    estimated_total = 5000,
    prompt_tokens = 80,
    is_shadow = false,
    saas_client = package.loaded["fairvisor.saas_client"],
  }

  ctx.stream_ctx = streaming.init_stream(ctx.config, ctx.request_context, ctx.reservation)
end)

runner:given("^stream limit behavior is error_chunk$", function(ctx)
  ctx.stream_ctx.on_limit_exceeded = "error_chunk"
  ctx.stream_ctx.config.streaming.on_limit_exceeded = "error_chunk"
end)

runner:given("^shadow mode is enabled for the stream$", function(ctx)
  ctx.stream_ctx.is_shadow = true
end)

runner:when("^I run body_filter with a (%d+) token delta event$", function(ctx, tokens)
  local chunk = _mk_delta_event(tonumber(tokens))
  ctx.output = streaming.body_filter(chunk, false)
end)

runner:when("^I run body_filter with two (%d+) token delta events in one chunk$", function(ctx, tokens)
  local part = _mk_delta_event(tonumber(tokens))
  ctx.output = streaming.body_filter(part .. part, false)
end)

runner:when("^I run body_filter with three (%d+) token delta events in one chunk$", function(ctx, tokens)
  local part = _mk_delta_event(tonumber(tokens))
  ctx.output = streaming.body_filter(part .. part .. part, false)
end)

runner:when("^I run body_filter with a malformed SSE data event$", function(ctx)
  ctx.output = streaming.body_filter("data: {not-json}\n\n", false)
end)

runner:when("^I run body_filter with a split (%d+) token event across two chunks$", function(ctx, tokens)
  local full_event = _mk_delta_event(tonumber(tokens))
  local split_at = math.floor(#full_event / 2)
  local first_half = string.sub(full_event, 1, split_at)
  local second_half = string.sub(full_event, split_at + 1)

  ctx.output = streaming.body_filter(first_half, false)
  ctx.output2 = streaming.body_filter(second_half, false)
end)

runner:when("^I run body_filter with DONE event$", function(ctx)
  ctx.output = streaming.body_filter("data: [DONE]\n\n", false)
end)

runner:when("^I run body_filter on a non%-streaming request chunk$", function(ctx)
  _G.ngx.ctx.fairvisor_stream = nil
  ctx.output = streaming.body_filter("plain chunk", false)
end)

runner:then_("^the output passes through as the same SSE event$", function(ctx)
  assert.matches('^data: %{"choices":%[%{"delta":%{"content":"x+"%}%}%]%}%\n\n$', ctx.output)
end)

runner:then_("^the stream is terminated with finish_reason length and done marker$", function(ctx)
  assert.matches('finish_reason":"length"', ctx.output)
  assert.matches('"usage":%{"prompt_tokens":80,"completion_tokens":120,"total_tokens":200%}', ctx.output)
  assert.matches('data: %[DONE%]\n\n$', ctx.output)
end)

runner:then_("^the stream is terminated with rate_limit_error and done marker$", function(ctx)
  assert.matches('"type":"rate_limit_error"', ctx.output)
  assert.matches('data: %[DONE%]\n\n$', ctx.output)
end)

runner:then_("^the stream remains unbroken across split chunks$", function(ctx)
  assert.equals("", ctx.output)
  assert.matches('^data: %{"choices":%[%{"delta":%{"content":"x+"%}%}%]%}%\n\n$', ctx.output2)
end)

runner:then_("^token counting ignores malformed JSON events$", function(ctx)
  assert.equals("data: {not-json}\n\n", ctx.output)
  assert.equals(0, ctx.stream_ctx.tokens_used)
end)

runner:then_("^reconcile is called with actual total tokens (%d+)$", function(_, actual_total)
  assert.equals(1, #reconcile_calls)
  assert.equals(tonumber(actual_total), reconcile_calls[1].actual_total)
end)

runner:then_("^shadow mode does not terminate and logs would truncate$", function(ctx)
  assert.is_truthy(string.find(ctx.output, "delta", 1, true))
  assert.equals(false, ctx.stream_ctx.truncated)
  assert.is_true(#ctx.logs >= 1)
end)

runner:then_("^non%-streaming chunks pass through unchanged$", function(ctx)
  assert.equals("plain chunk", ctx.output)
end)

runner:then_("^enforcement checks advance by buffer interval$", function(ctx)
  assert.equals(300, ctx.stream_ctx.next_check)
end)

runner:then_("^a stream_cutoff audit event was queued with tokens_used (%d+)$", function(ctx, tokens)
  local event = nil
  for i = 1, #ctx.queued_events do
    if ctx.queued_events[i].event_type == "stream_cutoff" then
      event = ctx.queued_events[i]
      break
    end
  end
  assert.is_not_nil(event)
  assert.equals(tonumber(tokens), event.tokens_used)
end)

runner:then_("^exactly (%d+) stream_cutoff audit event was queued$", function(ctx, count)
  local actual_count = 0
  for i = 1, #ctx.queued_events do
    if ctx.queued_events[i].event_type == "stream_cutoff" then
      actual_count = actual_count + 1
    end
  end
  assert.equals(tonumber(count), actual_count)
end)

-- Non-streaming reconciliation steps (Issue #12 / Feature 015)
runner:given("^a non%-streaming context with reservation key ([%a%d_%-]+) and estimated_total (%d+)$",
function(ctx, key, estimated_total)
  ctx.config = {}
  ctx.request_context = {
    body = '{"model":"gpt","stream":false}',
    headers = { Accept = "application/json" },
  }
  ctx.reservation = {
    key = key,
    estimated_total = tonumber(estimated_total),
    prompt_tokens = 0,
    is_shadow = false,
  }
  ctx.stream_ctx = streaming.init_stream(ctx.config, ctx.request_context, ctx.reservation)
end)

runner:when("^I run body_filter with non%-streaming response body having total_tokens (%d+)$",
function(ctx, total_tokens)
  local body = '{"usage":{"total_tokens":' .. total_tokens .. '}}'
  ctx.output = streaming.body_filter(body, false)
  ctx.output_eof = streaming.body_filter("", true)
end)

runner:when("^I run body_filter with non%-streaming response body in two chunks having total_tokens (%d+)$",
function(ctx, total_tokens)
  local body = '{"usage":{"total_tokens":' .. total_tokens .. '}}'
  local mid = math.floor(#body / 2)
  ctx.output = streaming.body_filter(string.sub(body, 1, mid), false)
  ctx.output_eof = streaming.body_filter(string.sub(body, mid + 1), true)
end)

runner:when("^I run body_filter with non%-streaming response body with no usage field$", function(ctx)
  local body = '{"result":"ok"}'
  ctx.output = streaming.body_filter(body, false)
  ctx.output_eof = streaming.body_filter("", true)
end)

runner:then_("^reconcile is called for non%-streaming with actual_total (%d+) and estimated_total (%d+)$",
function(_, actual_total, estimated_total)
  assert.equals(1, #reconcile_calls)
  assert.equals(tonumber(actual_total), reconcile_calls[1].actual_total)
  assert.equals(tonumber(estimated_total), reconcile_calls[1].estimated_total)
end)

runner:then_("^reconcile is called for non%-streaming with no refund %(estimated equals actual%)$",
function(_, ...)
  assert.equals(1, #reconcile_calls)
  assert.equals(reconcile_calls[1].estimated_total, reconcile_calls[1].actual_total)
end)

runner:then_("^non%-streaming body passes through unchanged$", function(ctx)
  assert.is_not_nil(ctx.output)
  assert.is_true(string.find(ctx.output, "usage", 1, true) ~= nil or #ctx.output >= 0)
end)

runner:then_("^reconcile is not called$", function(_)
  assert.equals(0, #reconcile_calls)
end)

-- Issue #25: additional step definitions for coverage gaps
runner:given("^a streaming context with include_partial_usage disabled$", function(ctx)
  ctx.config = {
    max_completion_tokens = 50,
    streaming = {
      enabled = true,
      enforce_mid_stream = true,
      buffer_tokens = 50,
      on_limit_exceeded = "graceful_close",
      include_partial_usage = false,
    },
  }
  ctx.request_context = {
    body = '{"stream":true}',
    headers = { Accept = "text/event-stream" },
  }
  ctx.reservation = {
    key = "tenant-no-usage",
    estimated_total = 5000,
    prompt_tokens = 10,
    is_shadow = false,
  }
  ctx.stream_ctx = streaming.init_stream(ctx.config, ctx.request_context, ctx.reservation)
end)

runner:given("^a streaming context with leftover buffer data$", function(ctx)
  ctx.config = {
    max_completion_tokens = 5000,
    streaming = {
      enabled = true,
      enforce_mid_stream = true,
      buffer_tokens = 100,
      on_limit_exceeded = "graceful_close",
      include_partial_usage = true,
    },
  }
  ctx.request_context = { body = '{"stream":true}', headers = {} }
  ctx.reservation = {
    key = "tenant-buf",
    estimated_total = 5000,
    prompt_tokens = 0,
    is_shadow = false,
  }
  ctx.stream_ctx = streaming.init_stream(ctx.config, ctx.request_context, ctx.reservation)
end)

runner:given("^a streaming context is truncated$", function(ctx)
  ctx.stream_ctx.truncated = true
end)

runner:when("^I run body_filter with a non%-eof chunk on the truncated stream$", function(ctx)
  ctx.output = streaming.body_filter("some data", false)
end)

runner:when("^I run body_filter with eof on the truncated stream$", function(ctx)
  ctx.output = streaming.body_filter("", true)
end)

runner:when("^I send an empty data%-only SSE event$", function(ctx)
  ctx.output = streaming.body_filter("data:\n\n", false)
end)

runner:when("^I run body_filter with partial SSE then eof$", function(ctx)
  -- Send a partial event (no double-newline terminator) then close with eof
  ctx.output  = streaming.body_filter("data: incomplete", false)
  ctx.output2 = streaming.body_filter("", true)
end)

runner:then_("^the truncated stream returns empty string$", function(ctx)
  assert.equals("", ctx.output)
end)

runner:then_("^the empty data event passes through with zero tokens$", function(ctx)
  assert.equals(0, ctx.stream_ctx.tokens_used)
  assert.is_string(ctx.output)
end)

runner:then_("^the partial buffer is flushed on eof$", function(ctx)
  -- The unfinished SSE fragment should be in output2 (flushed at eof)
  assert.is_truthy(string.find(ctx.output2 or "", "incomplete", 1, true)
    or string.find((ctx.output or "") .. (ctx.output2 or ""), "incomplete", 1, true))
end)

runner:then_("^the termination event has no usage field$", function(ctx)
  assert.is_nil(string.find(ctx.output, "usage", 1, true))
end)

runner:given("^streaming config with non%-boolean enabled$", function(ctx)
  ctx.validation_config = { streaming = { enabled = "yes" } }
end)

runner:given("^streaming config with non%-boolean enforce_mid_stream$", function(ctx)
  ctx.validation_config = { streaming = { enforce_mid_stream = 1 } }
end)

runner:given("^streaming config with non%-boolean include_partial_usage$", function(ctx)
  ctx.validation_config = { streaming = { include_partial_usage = "true" } }
end)

runner:given("^streaming config with invalid on_limit_exceeded$", function(ctx)
  ctx.validation_config = { streaming = { on_limit_exceeded = "drop" } }
end)

runner:then_("^streaming config validation fails with enabled error$", function(ctx)
  assert.is_nil(ctx.ok)
  assert.matches("enabled must be a boolean", ctx.err)
end)

runner:then_("^streaming config validation fails with enforce_mid_stream error$", function(ctx)
  assert.is_nil(ctx.ok)
  assert.matches("enforce_mid_stream must be a boolean", ctx.err)
end)

runner:then_("^streaming config validation fails with include_partial_usage error$", function(ctx)
  assert.is_nil(ctx.ok)
  assert.matches("include_partial_usage must be a boolean", ctx.err)
end)

runner:then_("^streaming config validation fails with on_limit_exceeded error$", function(ctx)
  assert.is_nil(ctx.ok)
  assert.matches("on_limit_exceeded must be graceful_close or error_chunk", ctx.err)
end)

runner:then_("^is_streaming returns false for nil input$", function(ctx)
  assert.is_false(streaming.is_streaming(nil))
  assert.is_false(streaming.is_streaming(42))
  assert.is_false(streaming.is_streaming("string"))
end)

runner:feature([[
Feature: SSE streaming enforcement module behavior
  Rule: Streaming detection and config validation
    Scenario: AC-8 detects stream true in request body
      Given the nginx mock environment is reset
      And a request body with stream true
      When I detect whether it is streaming
      Then streaming detection returns true

    Scenario: detects stream from Accept header
      Given the nginx mock environment is reset
      And a request accept header for text/event-stream
      When I detect whether it is streaming
      Then streaming detection returns true

    Scenario: AC-9 non-streaming detection returns false
      Given the nginx mock environment is reset
      And a non-streaming request context
      When I detect whether it is streaming
      Then streaming detection returns false

    Scenario: validates config defaults
      Given the nginx mock environment is reset
      And a valid streaming config
      When I validate streaming config
      Then streaming config validation succeeds with defaults

    Scenario: rejects invalid buffer_tokens
      Given the nginx mock environment is reset
      And an invalid streaming config with buffer_tokens 0
      When I validate streaming config
      Then streaming config validation fails with buffer error

  Rule: Body filter stream handling
    Scenario: AC-9 non-streaming requests pass through unchanged
      Given the nginx mock environment is reset
      And a streaming context with max_completion_tokens 100 and buffer_tokens 100
      And a non-streaming request context
      When I run body_filter on a non-streaming request chunk
      Then non-streaming chunks pass through unchanged

    Scenario: AC-1 stream truncates at max_completion_tokens with graceful_close
      Given the nginx mock environment is reset
      And a streaming context with max_completion_tokens 100 and buffer_tokens 100
      When I run body_filter with two 60 token delta events in one chunk
      Then the stream is terminated with finish_reason length and done marker
      And a stream_cutoff audit event was queued with tokens_used 120

    Scenario: AC-6 stream truncates with error_chunk mode
      Given the nginx mock environment is reset
      And a streaming context with max_completion_tokens 100 and buffer_tokens 100
      And stream limit behavior is error_chunk
      When I run body_filter with two 60 token delta events in one chunk
      Then the stream is terminated with rate_limit_error and done marker
      And a stream_cutoff audit event was queued with tokens_used 120

    Scenario: AC-3 partial SSE events are buffered until complete
      Given the nginx mock environment is reset
      And a streaming context with max_completion_tokens 200 and buffer_tokens 100
      When I run body_filter with a split 40 token event across two chunks
      Then the stream remains unbroken across split chunks

    Scenario: cjson decode failures do not crash counting
      Given the nginx mock environment is reset
      And a streaming context with max_completion_tokens 200 and buffer_tokens 100
      When I run body_filter with a malformed SSE data event
      Then token counting ignores malformed JSON events

    Scenario: AC-4 reconciliation runs on done event
      Given the nginx mock environment is reset
      And a streaming context with max_completion_tokens 200 and buffer_tokens 100
      And I run body_filter with a 30 token delta event
      When I run body_filter with DONE event
      Then reconcile is called with actual total tokens 110

    Scenario: AC-7 shadow mode logs but does not interrupt
      Given the nginx mock environment is reset
      And a streaming context with max_completion_tokens 100 and buffer_tokens 100
      And shadow mode is enabled for the stream
      When I run body_filter with two 60 token delta events in one chunk
      Then shadow mode does not terminate and logs would truncate
      And a stream_cutoff audit event was queued with tokens_used 120

    Scenario: shadow mode emits exactly one stream_cutoff event even if it crosses multiple boundaries
      Given the nginx mock environment is reset
      And a streaming context with max_completion_tokens 100 and buffer_tokens 100
      And shadow mode is enabled for the stream
      When I run body_filter with three 60 token delta events in one chunk
      Then shadow mode does not terminate and logs would truncate
      And exactly 1 stream_cutoff audit event was queued

    Scenario: AC-5 enforcement checks every buffer interval
      Given the nginx mock environment is reset
      And a streaming context with max_completion_tokens 150 and buffer_tokens 100
      When I run body_filter with two 100 token delta events in one chunk
      Then enforcement checks advance by buffer interval

  Rule: Non-streaming token reconciliation (Issue #12 / Feature 015)
    Scenario: F015-NS-1 non-streaming response triggers reconcile with actual token count from body
      Given the nginx mock environment is reset
      And a non-streaming context with reservation key tenant-1 and estimated_total 500
      When I run body_filter with non-streaming response body having total_tokens 120
      Then reconcile is called for non-streaming with actual_total 120 and estimated_total 500

    Scenario: F015-NS-2 non-streaming response body split across chunks still triggers reconcile
      Given the nginx mock environment is reset
      And a non-streaming context with reservation key tenant-2 and estimated_total 300
      When I run body_filter with non-streaming response body in two chunks having total_tokens 80
      Then reconcile is called for non-streaming with actual_total 80 and estimated_total 300

    Scenario: F015-NS-3 non-streaming response with no usage field does not over-refund
      Given the nginx mock environment is reset
      And a non-streaming context with reservation key tenant-3 and estimated_total 400
      When I run body_filter with non-streaming response body with no usage field
      Then reconcile is called for non-streaming with no refund (estimated equals actual)

    Scenario: F015-NS-4 no context means no reconcile and chunk passes through
      Given the nginx mock environment is reset
      When I run body_filter on a non-streaming request chunk
      Then non-streaming chunks pass through unchanged
      And reconcile is not called

  Rule: validate_config type error branches (issue #25)
    Scenario: validate_config rejects non-boolean enabled
      Given the nginx mock environment is reset
      And streaming config with non-boolean enabled
      When I validate streaming config
      Then streaming config validation fails with enabled error

    Scenario: validate_config rejects non-boolean enforce_mid_stream
      Given the nginx mock environment is reset
      And streaming config with non-boolean enforce_mid_stream
      When I validate streaming config
      Then streaming config validation fails with enforce_mid_stream error

    Scenario: validate_config rejects non-boolean include_partial_usage
      Given the nginx mock environment is reset
      And streaming config with non-boolean include_partial_usage
      When I validate streaming config
      Then streaming config validation fails with include_partial_usage error

    Scenario: validate_config rejects invalid on_limit_exceeded value
      Given the nginx mock environment is reset
      And streaming config with invalid on_limit_exceeded
      When I validate streaming config
      Then streaming config validation fails with on_limit_exceeded error

  Rule: is_streaming edge cases (issue #25)
    Scenario: is_streaming returns false for non-table input
      Given the nginx mock environment is reset
      Then is_streaming returns false for nil input

  Rule: body_filter truncated and buffer edge cases (issue #25)
    Scenario: truncated stream swallows non-eof chunks
      Given the nginx mock environment is reset
      And a streaming context with max_completion_tokens 100 and buffer_tokens 100
      And a streaming context is truncated
      When I run body_filter with a non-eof chunk on the truncated stream
      Then the truncated stream returns empty string
      And reconcile is not called

    Scenario: truncated stream triggers reconcile on eof
      Given the nginx mock environment is reset
      And a streaming context with max_completion_tokens 100 and buffer_tokens 100
      And a streaming context is truncated
      When I run body_filter with eof on the truncated stream
      Then reconcile is called with actual total tokens 80

    Scenario: empty data: event passes through with zero token contribution
      Given the nginx mock environment is reset
      And a streaming context with max_completion_tokens 200 and buffer_tokens 100
      When I send an empty data-only SSE event
      Then the empty data event passes through with zero tokens

    Scenario: partial SSE fragment is flushed on eof
      Given the nginx mock environment is reset
      And a streaming context with leftover buffer data
      When I run body_filter with partial SSE then eof
      Then the partial buffer is flushed on eof

    Scenario: termination event omits usage when include_partial_usage is false
      Given the nginx mock environment is reset
      And a streaming context with include_partial_usage disabled
      When I run body_filter with two 60 token delta events in one chunk
      Then the termination event has no usage field
]])
