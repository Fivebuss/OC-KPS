---@diagnostic disable: lowercase-global
-- Sets up "polaris" kernel I didnt have a better name


event = require("sys.kernel.modules.event")

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

--- Logging
polaris.log = require("sys.kernel.modules.log")
local function log(...) polaris.log(...) end
log("log initialized for " .. tostring(polaris.version.kernel))
log("Registered base modules: buffer, io, config, scheduler, log")

-- Spawn kernel thread
dofile("/sys/kernel/kernel.lua")
log("Kernel thread UID 1 spawned")

-- Syscalls
polaris.call = require("sys.kernel.modules.syscall")
log("Registered module: syscall")

-- Load tty to packages
polaris.tty = require("sys.kernel.modules.tty")
log("Registered module: tty")

-- Extending functionality for stuff

-- Search by prefix
function package.loadedNames(prefix)
  checkArg(1, prefix, "string")

  local result = {}

  for name in pairs(package.loaded) do
    if name == prefix or name:sub(1, #prefix + 1) == prefix .. "." then
      table.insert(result, name)
    end
  end

  return result
end

polaris.loadedModules = package.loadedNames("sys")

-- Replace os.sleep
function os.sleep(n)
  checkArg(1, n, "number")
  if polaris.scheduler.currentThread() then
    polaris.scheduler.sleep(seconds)
  else
    error("os.sleep called outside a scheduler thread")
  end

  return true
end

return ("Polaris " .. polaris.version.kernel .. " loaded")
