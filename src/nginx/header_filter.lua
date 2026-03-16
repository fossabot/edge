if ngx.ctx and ngx.ctx.wrapper_provider then
  local wrapper = require("fairvisor.wrapper")
  wrapper.strip_response_auth_headers()
  return
end

if ngx.var.fairvisor_mode ~= "reverse_proxy" then
  return
end

local decision_api = require("fairvisor.decision_api")
decision_api.header_filter_handler()
