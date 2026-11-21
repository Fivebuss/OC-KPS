-- /bin/events.lua
local event = require("event")
local computer = require("computer")

process.self().setHandle(process.SIG.INT, function()
    os.exit(130)
end)

local args = { ... }
for _, a in ipairs(args) do
    if a == "--help" then
        io.writeln("Usage: events")
        io.writeln("Shows incoming event signals")
        os.exit(0)
    end
end

-- discard initial
event.pull(0.05)
process.sleep(0.5)

while true do
    local e = { event.pull() }

    if e[1] == "INT" then
        os.exit(130)
    end

    io.write(tostring(computer.uptime()))

    for i = 1, #e do
        io.write("\t", tostring(e[i]))
    end

    io.write("\n")

    coroutine.yield()
end
