-- /bin/events.lua
local event = require("event")
local computer = require("computer")

-- discard initial
event.pull(0.05)
require("process").sleep(0.5)

while true do
    local e = {event.pull()}

    if e[1] == "INT" then
        os.exit(130)
    end

    io.write(tostring(computer.uptime()))

    for i = 1, #e do
        io.write("\t", tostring(e[i]))
    end

    io.write("\n")

    if coroutine.yield() == "INT" then
        os.exit(130)
    end
end
