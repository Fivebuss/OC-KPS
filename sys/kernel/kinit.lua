---@diagnostic disable: lowercase-global
-- Sets up "polaris" kernel I didnt have a better name

event = require("sys.kernel.modules.event")

polaris = {} -- global
polaris.version = {}
polaris.version.os = _G._OSVERSION
polaris.version.kernel = "Polaris Kernel 0.1"
_G._OSVERSION = nil
polaris.syscalls = {}
polaris.config = {}
-- Load config

require("sys.kernel.modules.config")()

-- Init scheduler
polaris.scheduler = require("sys.kernel.modules.scheduler")
local interval = polaris.config["interval"] or 0.05
polaris.scheduler.interval = interval

polaris.scheduler.handler = polaris.scheduler.init(event, interval)

-- Initialize kernel modules
require("sys.kernel.modules.syscall")

-- Spawn idle thread
dofile("/sys/kernel/idle.lua")

-- Load tty to packages
polaris.tty = require("sys.kernel.modules.tty")
