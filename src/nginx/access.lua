local mode = ngx.var.fairvisor_mode

if mode == "wrapper" then
  local wrapper = require("fairvisor.wrapper")
  wrapper.access_handler()
  return
end

if mode ~= "reverse_proxy" then
  return
end

local decision_api = require("fairvisor.decision_api")
decision_api.access_handler()
