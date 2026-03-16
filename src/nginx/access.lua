local mode = ngx.var.fairvisor_mode

if mode == "wrapper" then
  local wrapper = require("fairvisor.wrapper")
  wrapper.access_handler()
  return
end

if mode == "hybrid" then
  local wrapper = require("fairvisor.wrapper")
  local provider = wrapper.get_provider(ngx.var.uri or "")
  if provider then
    wrapper.access_handler()
    return
  end
  -- No provider match — fall through to decision_api enforcement
end

if mode ~= "reverse_proxy" and mode ~= "hybrid" then
  return
end

local decision_api = require("fairvisor.decision_api")
decision_api.access_handler()
