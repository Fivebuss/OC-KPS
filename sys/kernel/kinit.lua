---@diagnostic disable: lowercase-global
-- Sets up "polaris" kernel I didnt have a better name
package.path =
"/lib/?.lua;/lib/?/init.lua;/lib/?/?.lua;/usr/lib/?.lua;/usr/lib/?/init.lua;/usr/lib/?/?.lua;/home/lib/?.lua;/home/lib/?/init.lua;/home/lib/?/?.lua;/home/?.lua;/home/?/init.lua;/home/?/?.lua;./?.lua;./?/init.lua;./?/?.lua;/sys/kernel/modules/?.lua"
local event_internals = require("event_internals")
local component = require("component")
local package = require("package")
local filesystem = require("filesystem")

polaris = {} -- global
polaris.version = {}
polaris.version.os = _G._OSVERSION
polaris.version.kernel = "Polaris Kernel 0.2"
_G._OSVERSION = nil
polaris.syscalls = {}
polaris.config = {}
polaris.analytics = { boot = {} }

status(polaris.version.kernel .. ": kinit exec, setting up kernel")

function polaris.analytics.addEvent(name)
    polaris.analytics.boot[name] = { uptime = computer.uptime(), clock = os.clock() }
end

polaris.analytics.addEvent("kinit_start")

-- Load config
do
    local path = "/boot/polaris/kconfig.cfg"
    local cfg = dofile(path)

    if type(cfg) ~= "table" then
        error("Config file must return table: " .. path)
    end

    polaris.config = cfg
end

local debugMode = polaris.config["debug"]

-- Load compiled kmodules
do
    local bundle = dofile("/sys/kernel/kmodules.lua")
    for name, src in pairs(bundle) do
        local chunk, err = load(src, "=" .. name, "bt", _G)

        if not chunk then
            error("Failed to compile module " .. name .. ": " .. err)
        end

        package.preload[name] = function()
            return chunk()
        end
    end
end

-- Buffer and io
polaris.buffer = require("buffer")
polaris.io = require("io")

-- Initialize kernel modules
polaris.scheduler = require("scheduler")
local interval = polaris.config["interval"] or 0.05
polaris.scheduler.interval = interval

polaris.scheduler.handler = polaris.scheduler.init(event_internals, interval)

-- Process managemen for stdio and everything
polaris.process = require("process")

--Logging
polaris.log = require("log")
local function log(...)
    if status == true and debugMode == true then status(...) end
    polaris.log(...)
end

if debugMode == true then function _G.klog(...) log(...) end end

log("log initialized for " .. tostring(polaris.version.kernel))
log("Registered base modules: buffer, io, process, config, scheduler, log")

-- Spawn kernel thread
dofile("/sys/kernel/kernel.lua")
log("Kernel thread UID 1 spawned")

-- Syscalls
polaris.call = require("syscall")
log("Registered module: syscall")

-- Load tty to packages
polaris.tty = require("tty")
log("Registered module: tty")

-- Component stuff
for c, t in component.list() do
    computer.pushSignal("component_added", c, t)
end

-- devfs time
polaris.devfs = require("devfs")
polaris.devfs.mount(polaris.config["devroot"] or "/dev")
polaris.devfs.register(polaris.devfs.proxy)
log("Registered module: devfs\ndevfs: mounted devfs to /dev")
polaris.procfs = require("procfs")
polaris.procfs.register(polaris.devfs)
filesystem.mount(filesystem.internal.proxy("/dev/proc", { bind = true }), "/proc")
log("Registered module: procfs\nprocfs: mounted procfs to /dev/proc and /proc")

-- Mount tmp
if computer.tmpAddress() then
    filesystem.mount(computer.tmpAddress(), "/tmp")
end

-- Service time
polaris.services = require("services")
log("Registered module: services")

polaris.panic = function()
    local w, h = polaris.gpu.getResolution()
    polaris.gpu.fill(1, 1, w, h, " ")

    local y = 1
    --local w, h = 0, 0

    local function status(msg)
        msg = tostring(msg)

        polaris.gpu.set(1, y, msg)

        if y == h then
            polaris.gpu.copy(1, 2, w, h - 1, 0, -1)
            polaris.gpu.fill(1, h, w, 1, " ")
        else
            y = y + 1
        end
    end

    log("panic()")
    log(debug.traceback())
    polaris.scheduler.deinit(event_internals, polaris.scheduler.handler)
    for line in tostring(polaris.log):gmatch("([^\n]*)\n") do
        status(line)
    end
    while true do
        computer.pullSignal(0)
    end
end

polaris.analytics.addEvent("kinit_end")
return ("Polaris " .. polaris.version.kernel .. " loaded")
