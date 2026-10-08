---@diagnostic disable: lowercase-global
-- Sets up "polaris" kernel I didnt have a better name
package.path = "/lib/?.lua;/usr/lib/?.lua;/home/lib/?.lua;./?.lua;/lib/?/init.lua;/usr/lib/?/init.lua;/home/lib/?/init.lua;./?/init.lua;/sys/kernel/modules/?.lua"

local event_internals = require("event_internals")
local component = require("component")
local package = require("package")
local filesystem = require("filesystem")

polaris = {} -- global
polaris.version = {}
polaris.version.os = _G._OSVERSION
polaris.version.kernel = "Polaris Kernel 0.1"
_G._OSVERSION = nil
polaris.syscalls = {}
polaris.config = {}
polaris.analytics = { boot = {} }
local debug = polaris.config["debug"]

status(polaris.version.kernel .. ": kinit exec, setting up kernel")
if debug then
    _G.status = nil
end

function polaris.analytics.addEvent(name)
    polaris.analytics.boot[name] = { uptime = computer.uptime(), clock = os.clock() }
end

polaris.analytics.addEvent("kinit_start")

-- This is now just a boot gpu
polaris.gpu = gpu
if debug ~= true then
    _G.gpu = nil
end

-- Load config

require("config")()

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

--- Logging
polaris.log = require("log")
local function log(...)
    if status == true and debug == true then status(...) end
    polaris.log(...)
end

if debug == true then function _G.klog(...) log(...) end end

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
dofile("sys/kernel/modules/component.lua")
package.loaded["component"] = component
log("Registered module: component")

-- devfs time
polaris.devfs = require("devfs")
filesystem.mount(polaris.devfs.proxy, "/dev")
polaris.devfs.register(polaris.devfs.proxy)
log("Registered module: devfs\ndevfs: mounted /dev")

-- Mount tmp
if computer.tmpAddress() then
    filesystem.mount(computer.tmpAddress(), "/tmp")
end

-- Service time
polaris.services = require("services")
log("Registered module: services")

polaris.analytics.addEvent("kinit_end")
return ("Polaris " .. polaris.version.kernel .. " loaded")
