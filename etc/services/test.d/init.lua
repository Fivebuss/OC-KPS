-- /etc/services/privileged/test.d/init.lua

-- Test service
-- You can see here you must use process.write
-- Stdout and stderr go to the service log
-- You must define a svc module and export at minimum start() and stop()

local event = require("event")
local process = polaris.process

local svc = {}

function svc.start(name)
    process.write("test.d start() ran! Hello there. Stderr in 5 seconds\n")
    process.sleep(5)
    process.writeError("Stderr, hello\n")
    process.write("Now waiting...\n")
    process.waitForInput() -- This will wait until the process receives a signal, or stops/restarts
    process.write("Input received, bye\n")
    -- Upon returning, the service will stop
end

function svc.stop(name)
    -- As i/o is already destroyed by this point, you cannot do process.write()
    return "Return stop" -- This is viewed nowhere, stop return values do not exist
end

function svc.custom(...)
    local args = {...}

    -- You cannot write to stdout from custom functions! These are intended for say config changes.
    if #args ~= 0 then
        -- Instead,
        return "Arguements to custom():" .. tostring(args[1])
        -- Will write to the output as [svc]
    end
    return "No arguements"
end

return svc