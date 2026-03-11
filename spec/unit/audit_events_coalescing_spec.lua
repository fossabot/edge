package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local saas_client = require("fairvisor.saas_client")
local gherkin = require("helpers.gherkin")
local mock_ngx = require("helpers.mock_ngx")
local mock_http = require("helpers.mock_http")

local runner = gherkin.new({ describe = describe, context = context, it = it })

runner:given("^the SaaS client is initialized for coalescing tests$", function(ctx)
  local env = mock_ngx.setup_ngx()
  ctx.time = env.time
  ctx.timers = {}
  ngx.timer = {
    every = function(interval, fn)
      ctx.timers[#ctx.timers + 1] = { interval = interval, fn = fn }
      return true
    end,
  }

  ctx.config = {
    edge_id = "edge-coalesce",
    edge_token = "token-1",
    saas_url = "https://saas.example",
    max_batch_size = 10,
    max_buffer_size = 100,
    heartbeat_interval = 5,
    event_flush_interval = 60,
  }

  local http_env = mock_http.new()
  ctx.http = http_env

  -- Registration
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/register", { status = 200 })
  -- Events
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/events", { status = 200 })
  -- Summary Events (second batch)
  ctx.http.queue_response("POST", ctx.config.saas_url .. "/api/v1/edge/events", { status = 200 })

  local ok, err = saas_client.init(ctx.config, {
    http_client = http_env.client,
    bundle_loader = {
      get_current = function() return nil end,
      load_from_string = function() return nil, "not_implemented" end,
      apply = function() return true end,
    },
    health = {
      set = function() return true end,
      inc = function() return true end,
    }
  })
  assert.is_true(ok, "saas_client init failed: " .. tostring(err))
  assert.equals(2, #ctx.timers, "Should have registered 2 timers")
end)

runner:when("^I queue identical request_rejected events (%d+) times$", function(ctx, count)
  local event = {
    event_type = "request_rejected",
    subject_id = "user-1",
    route = "/v1/chat",
    reason_code = "rate_limited",
    status_code = 429
  }
  for _ = 1, tonumber(count) do
    saas_client.queue_event(event)
  end
end)

runner:when("^the event flush timer runs$", function(ctx)
  -- The flush timer in saas_client calls _event_flush_tick which calls _flush_coalesced_to_buffer
  ctx.timers[2].fn(false)
end)

runner:then_("^one initial rejection event and one summary event are sent to SaaS$", function(ctx)
  local has_initial = false
  local has_summary = false

  for _, req in ipairs(ctx.http.requests) do
    if req.url == ctx.config.saas_url .. "/api/v1/edge/events" then
      for _, event in ipairs(req.body.events) do
        if event.event_type == "request_rejected" then
          if event.repeated_count == nil then
            has_initial = true
          else
            has_summary = true
            assert.is_number(event.repeated_count)
            assert.is_number(event.window_sec)
          end
        end
      end
    end
  end

  assert.is_true(has_initial, "Should have sent initial event")
  assert.is_true(has_summary, "Should have sent summary event")
end)

runner:feature([[
Feature: Audit event coalescing
  Scenario: Identical rejections are coalesced
    Given the SaaS client is initialized for coalescing tests
    When I queue identical request_rejected events 5 times
    And the event flush timer runs
    Then one initial rejection event and one summary event are sent to SaaS
]])
