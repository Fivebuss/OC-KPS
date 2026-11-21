-- /bin/hwclock.lua
-- just use uptime...
local clock = os.clock()
local uptime = computer.uptime()

for _, a in ipairs(args or {}) do
    if a == "--help" then
        io.writeln("Usage: hwclock [-c]")
        io.writeln("Displays the computer's clock info")
        io.writeln("Defaults to uptime")
        io.writeln("  -c, displays the 'wall-clock' executor time")
        os.exit(0)
    end
end

if #args == 1 and args[1] == "-c" then
    io.writeln(clock)
else
    io.writeln(uptime)
end