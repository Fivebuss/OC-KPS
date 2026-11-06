-- /bin/hwclock.lua
-- just use uptime...
local clock = os.clock()
local uptime = computer.uptime()

if #args == 1 and args[1] == "-c" then
    io.writeln(clock)
else
    io.writeln(uptime)
end