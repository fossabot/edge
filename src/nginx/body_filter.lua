local streaming = require("fairvisor.streaming")
local output = streaming.body_filter(ngx.arg[1], ngx.arg[2])
if output ~= nil then
  ngx.arg[1] = output
end
