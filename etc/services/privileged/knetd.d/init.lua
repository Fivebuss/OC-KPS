-- /etc/services/privileged/knetd.d/init.lua
-- knetd, actual code is in lib/network/stack.lua

local stack = require("network.stack")
local svc = {}

function svc.start(name)
    local ok, err = stack.start()
    if not ok then
        error("knetd: failed to start: " .. tostring(err), 0)
    end

    local loopOk, loopErr = stack.loop()
    if not loopOk then
        error("knetd: " .. tostring(loopErr), 0)
    end

    return true
end

function svc.stop(name)
    stack.stop()
    return true
end

return svc
