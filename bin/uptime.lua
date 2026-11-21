-- /bin/uptime.lua

local getopt = require("ksh.getopt")

local uptime = computer.uptime()
local args = { ... }

local pretty = false
local raw = false
local since = false

for opt, val in getopt(args, "prsH", { ["help"] = "H" }) do
    if opt == "p" then
        pretty = true
    elseif opt == "r" then
        raw = true
    elseif opt == "s" then
        since = true
    elseif opt == "H" then
        io.writeln("Usage: uptime [-p] [-r] [-s]")
        io.writeln("Displays the current uptime, or when the system started")
        io.writeln("  -p, display in days, hours, minutes")
        io.writeln("  -r, the raw uptime. Default")
        io.writeln("  -s, estimate system start time")
        io.writeln("Note about -s")
        io.writeln("The game always starts at time 0 in the unix epoch time format")
        io.writeln("As such, -s will be relative to that")
        os.exit(0)
    elseif opt == "?" then
        io.writelnError("uptime: unrecognized option '" .. tostring(val) .. "'")
        os.exit(1)
    end
end

local modes = 0
if pretty then modes = modes + 1 end
if raw then modes = modes + 1 end
if since then modes = modes + 1 end

if modes > 1 then
    io.writelnError("uptime: -p, -r and -s are mutually exclusive")
    os.exit(1)
end

if pretty then
    local days = math.floor(uptime / 86400)
    local hours = math.floor((uptime % 86400) / 3600)
    local minutes = math.floor((uptime % 3600) / 60)

    local parts = {}

    if days > 0 then
        parts[#parts + 1] = days .. (days == 1 and " day" or " days")
    end

    if hours > 0 then
        parts[#parts + 1] = hours .. (hours == 1 and " hour" or " hours")
    end

    if minutes > 0 or #parts == 0 then
        parts[#parts + 1] = minutes .. (minutes == 1 and " minute" or " minutes")
    end

    io.writeln("up " .. table.concat(parts, ", "))
elseif since then
    local currentTime = os.time()
    local startTime = os.difftime(currentTime, uptime)

    io.writeln(os.date("%c", startTime))
else
    io.writeln(uptime)
end
