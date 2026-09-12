---@diagnostic disable: lowercase-global
-- Sets up "polaris" kernel I didnt have a better name

-- Global
event = require("sys.kernel.modules.event")
component = require("component")
local package = require("package")

polaris = {}   -- global
polaris.version = {}
polaris.version.os = _G._OSVERSION
polaris.version.kernel = "Polaris Kernel 0.1"
_G._OSVERSION = nil
polaris.syscalls = {}
polaris.config = {}
-- Load config

require("sys.kernel.modules.config")()

-- Buffer and io
polaris.buffer = require("sys.kernel.modules.buffer")
polaris.io = require("sys.kernel.modules.io")

-- Initialize kernel modules
polaris.scheduler = require("sys.kernel.modules.scheduler")
local interval = polaris.config["interval"] or 0.05
polaris.scheduler.interval = interval

polaris.scheduler.handler = polaris.scheduler.init(event, interval)

-- Process management: owns per-process (scheduler uid) stdio, and will
-- later own i/o routing between processes, child tracking, and signal
-- propagation. Needs scheduler + io, so load it after both.
polaris.process = require("sys.kernel.modules.process")

--- Logging
polaris.log = require("sys.kernel.modules.log")
local function log(...) polaris.log(...) end
log("log initialized for " .. tostring(polaris.version.kernel))
log("Registered base modules: buffer, io, process, config, scheduler, log")

-- Spawn kernel thread
dofile("/sys/kernel/kernel.lua")
log("Kernel thread UID 1 spawned")

-- Syscalls
polaris.call = require("sys.kernel.modules.syscall")
log("Registered module: syscall")

-- Load tty to packages
polaris.tty = require("sys.kernel.modules.tty")
log("Registered module: tty")

-- Component stuff
for c, t in component.list() do
  computer.pushSignal("component_added", c, t)
end
dofile("sys/kernel/modules/component.lua")
package.loaded["sys.kernel.modules.component"] = component
log("Registered module: component")


return ("Polaris " .. polaris.version.kernel .. " loaded")