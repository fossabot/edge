-- nginx body_filter phase handler for FAIRVISOR_MODE=wrapper.
-- Delegates SSE token counting to streaming.body_filter(), then replaces
-- the OpenAI-style cutoff sequence with the provider-native format.

if not ngx.ctx or not ngx.ctx.wrapper_provider then
  return
end

local streaming = require("fairvisor.streaming")
local wrapper   = require("fairvisor.wrapper")

local output = streaming.body_filter(ngx.arg[1], ngx.arg[2])
if output ~= nil then
  ngx.arg[1] = output
end

-- Post-process: if streaming.lua injected an OpenAI-style cutoff and the
-- provider needs a different format, replace it.
local provider = ngx.ctx.wrapper_provider
if provider and provider.cutoff_format and provider.cutoff_format ~= "openai" then
  local current = ngx.arg[1]
  if type(current) == "string" and current ~= "" then
    ngx.arg[1] = wrapper.replace_openai_cutoff(current, provider.cutoff_format)
  end
end
