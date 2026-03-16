-- Wrapper mode: provider-aware streaming cutoff handled by wrapper_body_filter
if ngx.ctx and ngx.ctx.wrapper_provider then
  local streaming = require("fairvisor.streaming")
  local wrapper   = require("fairvisor.wrapper")
  local output = streaming.body_filter(ngx.arg[1], ngx.arg[2])
  if output ~= nil then
    ngx.arg[1] = output
  end
  local provider = ngx.ctx.wrapper_provider
  if provider and provider.cutoff_format and provider.cutoff_format ~= "openai" then
    local current = ngx.arg[1]
    if type(current) == "string" and current ~= "" then
      ngx.arg[1] = wrapper.replace_openai_cutoff(current, provider.cutoff_format)
    end
  end
  return
end

local streaming = require("fairvisor.streaming")
local output = streaming.body_filter(ngx.arg[1], ngx.arg[2])
if output ~= nil then
  ngx.arg[1] = output
end
