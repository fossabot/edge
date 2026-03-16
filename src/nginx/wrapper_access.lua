-- nginx access phase handler for FAIRVISOR_MODE=wrapper.
-- Delegates entirely to fairvisor.wrapper.access_handler().
if ngx.var.fairvisor_mode ~= "wrapper" then
  return
end

local wrapper = require("fairvisor.wrapper")
wrapper.access_handler()
