-- /etc/services/privileged/test.d/init.lua

-- Test service
-- You can see here you must use process.write, to write in general use ...
-- Stdout and stderr go to the service log
-- Yielding or checkCancel, which will likely be depreciated eventually. Definitely mandatory like any process's loops
local event = require("event")
local process = polaris.process
local name = ...

local i = 0
while true do
    i = i + 1
    event.push("beacon")
    process.write(name, " log ", i, "\n")
    process.sleep(10)
    coroutine.yield()
end