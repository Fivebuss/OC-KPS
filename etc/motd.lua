local computer = require("computer")
local condraw = require("ksh.condraw")
local process = require("process")

local version = getenv("VERSION")

local total = computer.totalMemory() / 1024
local free = computer.freeMemory() / 1024

local boot = polaris.analytics and polaris.analytics.boot or {}
local ksh = boot["kshlaunch-" .. process.self().uid]

local reached
if ksh and ksh.uptime then
    local elapsed = computer.uptime() - ksh.uptime
    reached = string.format("%.3fs", elapsed)
else
    reached = "unknown"
end

local text = string.format(
    "ksh v%s\n%s\n%.1fK total %.1fK free\nReached ksh in %s",
    version,
    "",
    total,
    free,
    reached
)

local motd = condraw.box(text)

io.writeln("\27[38;2;255;255;255m" .. motd .. "\27[0m")