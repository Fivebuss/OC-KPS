-- /sys/kernel/modules/procfs.lua
--[[
Procfs is soo cool that I had to include it. Yes 99% of this I just shoved from mshell into here
But on the bright side memory shouldnt be aweful as I am putting this in devfs
And loading things at use instead of before hand
--]]

local computer = require("computer")
local component = require("component")
local filesystem = require("filesystem")
local package = require("package")

local process = polaris.process
local scheduler = polaris.scheduler
local version = polaris.version

local procfs = {}

local function statusChar(e)
    if e.protected then return "K" end
    if e.stopped then return "T" end
    if e.cancelled then return "C" end
    if e.sleeping then return "S" end
    if e.waiting then return "W" end

    if e.status == "running" then return "R" end
    if e.status == "normal" then return "N" end
    if e.status == "dead" then return "Z" end

    return "I"
end

local GID_NAMES = {}
for name, gid in pairs(process.GID) do
    if type(gid) == "number" then
        GID_NAMES[gid] = name
    end
end

local function gidName(gid)
    if gid == nil then return "-" end
    return GID_NAMES[gid] or tostring(gid)
end

local function row(label, value)
    return string.format("%-14s %s", label, tostring(value))
end

-- Fd 0,1,2 really. Custom fds soon(?)
local function fdList(pid)
    local list = {}

    for fd = 0, 2 do
        list[tostring(fd)] = {
            read = function()
                local fds = process.describe(pid)
                local desc = fds and fds[fd]

                if not (desc and desc.present) then
                    return "none\n"
                end

                return (desc.kind or "?") .. "\n"
            end
        }
    end

    return list
end

local function pidList(pid)
    local function face(fn)
        return {
            read = function()
                local e = process.get(pid)
                if not e then return "no such process\n" end
                return fn(e)
            end
        }
    end

    return {
        cmdline = face(function(e) return (e.cmd or "?") .. "\n" end),
        pid     = face(function(e) return tostring(e.pid) .. "\n" end),
        ppid    = face(function(e) return tostring(e.ppid or "-") .. "\n" end),
        uid     = face(function(e) return tostring(e.uid or "-") .. "\n" end),
        gid     = face(function(e) return gidName(e.gid) .. "\n" end),
        ctty    = face(function(e) return (e.ctty and e.ctty:match("(%x%x%x%x)$") or "-") .. "\n" end),
        stat    = face(function(e)
            return ("%s %s %s %s %s %s\n"):format(
                tostring(e.pid), tostring(e.ppid or "-"), tostring(e.uid or "-"),
                tostring(e.gid or "-"), statusChar(e), e.cmd or "?"
            )
        end),
        status  = face(function(e)
            local ctty = e.ctty and e.ctty:match("(%x%x%x%x)$") or "-"

            return ("%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n"):format(
                row("cmd", e.cmd or "?"),
                row("label", e.label or "-"),
                row("state", statusChar(e)),
                row("pid", tostring(e.pid)),
                row("ppid", tostring(e.ppid or "-")),
                row("uid", tostring(e.uid or "-")),
                row("gid", gidName(e.gid)),
                row("ctty", ctty),
                row("age", e.age or 0)
            )
        end),
        fd      = { list = function() return fdList(pid) end },
    }
end

-- /dev/proc/self
local function selfList()
    local pid = scheduler.activeThread()
    if not pid or not process.exists(pid) then
        return {}
    end

    return pidList(pid)
end

local function meminfoRead()
    local total = computer.totalMemory()
    local free = computer.freeMemory()

    return ("%s\n%s\n%s\n"):format(
        row("Total", total),
        row("Used", total - free),
        row("Free", free)
    )
end

local function uptimeRead()
    return ("%.2f\n"):format(computer.uptime())
end

local function statRead()
    return ("%s\n%s\n"):format(
        row("Processes", #process.list()),
        row("Threads", scheduler.threadCount())
    )
end

local function versionRead()
    return ("%s\n%s\n"):format(
        row("OS", version.os),
        row("Kernel", version.kernel)
    )
end

local function loadavgRead()
    return ("%s\n"):format(row("Threads", scheduler.threadCount()))
end

-- Kernel modules and if theyre loaded
local function modulesRead()
    if not filesystem.exists("/sys/kernel/modules") then
        return "modules directory unreachable, how are you even viewing this?\n"
    end

    local set = {}
    for file in filesystem.list("/sys/kernel/modules") do
        if file:sub(-4) == ".lua" then
            local name = file:sub(1, -5)
            set[name] = package.loaded[name] ~= nil
        end
    end

    local names = {}
    for name in pairs(set) do
        names[#names + 1] = name
    end
    table.sort(names)

    local out = {}
    for _, name in ipairs(names) do
        out[#out + 1] = string.format("%-18s %s", name, set[name] and "loaded" or "not loaded")
    end

    return table.concat(out, "\n") .. "\n"
end

-- cpuinfo yay
local function cpuinfoRead()
    local info = component.computer.getDeviceInfo()
    local arch = computer.getArchitecture()
    local support = table.concat(computer.getArchitectures(), ", ")

    local blocks = {}
    for addr, item in pairs(info) do
        if type(item) == "table" and item.class == "processor" then
            blocks[#blocks + 1] = ("%s\n%s\n%s\n%s\n%s"):format(
                row("address", addr),
                row("clock", item.clock),
                row("architecture", arch),
                row("architectures", support),
                row("type", item.description)
            )
        end
    end

    return table.concat(blocks, "\n\n") .. "\n"
end

local function rootList()
    local list = {
        self    = { list = selfList },
        meminfo = { read = meminfoRead },
        uptime  = { read = uptimeRead },
        stat    = { read = statRead },
        version = { read = versionRead },
        loadavg = { read = loadavgRead },
        modules = { read = modulesRead },
        cpuinfo = { read = cpuinfoRead },
    }

    for _, e in ipairs(process.list()) do
        local pid = e.pid
        list[tostring(pid)] = { list = function() return pidList(pid) end }
    end

    return list
end

-- /dev because I want to save ram
function procfs.register(devfs)
    checkArg(1, devfs, "table")
    devfs.define("proc", function()
        return { proc = { list = rootList } }
    end)
    return true
end

return procfs
