-- /bin/sys.lua
-- I can show off how fast it boots lol


-- sys [-v]   status
-- sys -c     syscalls
-- sys -e     current environment
-- sys -b     boot time stuff

local getopt = require("ksh.getopt")

local want, verbose = {}, false
local longSpec = { syscalls = "c", env = "e", boot = "b", verbose = "v" }
for opt, val in getopt(args, "cembv", longSpec) do
    if opt == "v" then
        verbose = true
    elseif opt == "?" then
        io.writelnError("sys: unrecognized option '" .. tostring(val) .. "'")
        return
    else
        want[opt] = true
    end
end

local function secs(t) return string.format("%.3fs", t) end
local function row(label, value) io.writeln(string.format("%-14s %s", label, tostring(value))) end

local function sortedNames(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = tostring(k) end
    table.sort(out)
    return out
end

local function status()
    local total, free = computer.totalMemory(), computer.freeMemory()
    local names = polaris.services.list()
    local running = 0
    for _, name in ipairs(names) do
        if polaris.services.status(name).state == "running" then running = running + 1 end
    end

    row("OS", polaris.version.os)
    row("Kernel", polaris.version.kernel)
    row("Uptime", secs(computer.uptime()))
    row("Memory", string.format("%d / %d bytes used", total - free, total))
    row("Processes", #polaris.process.list())
    row("Services", string.format("%d running / %d", running, #names))

    if verbose then
        row("Threads", polaris.scheduler.threadCount())
        row("Syscalls", #sortedNames(polaris.syscalls))
        row("Environment", #sortedNames(_ENV) .. " entries")
        for _, key in ipairs(sortedNames(polaris.config)) do
            row("config." .. key, polaris.config[key])
        end
    end
end

local function syscalls()
    for _, name in ipairs(sortedNames(polaris.syscalls)) do io.writeln(name) end
end

local function environment()
    for _, name in ipairs(sortedNames(_ENV)) do
        row(name, type(_ENV[name]))
    end
end


local EVENTS = {
    { "kinit_start", "kinit start" },
    { "kinit_end", "kinit end" },
    { "stage2", "stage 2" },
    { "ksh", "ksh" },
    { "console", "console" },
}

local function boot()
    local events = polaris.analytics and polaris.analytics.boot or {}
    local fmt = "%-12s %10s %10s %10s"

    io.writeln(string.format(fmt, "MARK", "UPTIME", "CLOCK", "DELTA"))
    local prev
    for _, m in ipairs(EVENTS) do
        local t = events[m[1]]
        if t then
            io.writeln(string.format(fmt, m[2], secs(t.uptime), secs(t.clock), prev and secs(t.uptime - prev) or "-"))
            prev = t.uptime
        else
            io.writeln(string.format(fmt, m[2], "-", "-", "-"))
        end
    end

    local first, console = events.kinit_start, events.console
    if console then
        io.writeln(string.format("Reached console in %s (%s since kinit started)",
            secs(console.uptime), first and secs(console.uptime - first.uptime) or "?"))
    else
        io.writeln("Console not reached yet")
    end
    io.writeln("Uptime: " .. secs(computer.uptime()) .. " | Clock: " .. secs(os.clock()))
end

local sections = {
    { "c", "syscalls", syscalls },
    { "e", "environment", environment },
    { "b", "boot", boot },
}

local selected = {}
for _, s in ipairs(sections) do
    if want[s[1]] then selected[#selected + 1] = s end
end

if #selected == 0 then
    return status()
end

for i, s in ipairs(selected) do
    if #selected > 1 then
        if i > 1 then io.writeln("") end
        io.writeln("== " .. s[2] .. " ==")
    end
    s[3]()
end