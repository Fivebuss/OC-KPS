-- Polaris syscalls
local event = require("sys.kernel.modules.event")
local computer = require("computer")

local function prepareHalt(signal)
    event.push(tostring(signal))
    local selfUid = polaris.scheduler.currentThread()
    polaris.scheduler.killAll(selfUid)  -- exclude the caller
    polaris.scheduler.cleanup(event)
    polaris.scheduler.deinit(event, polaris.scheduler.handler)
end

-- Yay
function polaris.call(syscall, ...)
    local handler = polaris.syscalls[syscall]

    if not handler then
        error("Unknown syscall: " .. tostring(syscall))
    end

    return handler(...)
end

polaris.syscalls.shutdown = function()
    prepareHalt("shutdown")
    computer.shutdown()
end
