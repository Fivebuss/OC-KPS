-- /sys/kernel/modules/services.lua
--[[
Privileged services, yeah they run in kernel space. I will use it for minitel probably
User ones maybe sometime later?
/etc/services/privileged/<name>.d/*

Hey look! I did a thing. Services are like modules now
start() is ran when the service is started
stop()  is ran when the service is stopped (optional but like why wouldnt you have one)
If there is no stop, the service is cancelled then eventually killed
Use any arbitrary functions, usable via rc <name> <func> [args...]
You cannot define 'restart' or 'status' as functions.

Process stuff:
GID is #3, SVC
PPID is 1, the kernel
Uses types stream,custom,custom for i/o
Shares the _ENV with kernel, and so things get copied downwards

services.load() / boot(): scan everything and deal with autostarts
services.start(name, delay) / stop(name) / restart(name): nil, reason on failure
services.call(name, func, ...): call a exported function on a running service
services.list(): names by their priority, services.status(name), services.log(name)
services.halt(): Stop dealing with exits
]]

local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local env = require("env")
local ring = require("ringbuffer")

local process = polaris.process
local kernelEnv = _G

local ROOT = "/etc/services/privileged"
local DEFAULTS = { priority = 0, onExit = "stop", autostart = true, restartDelay = 1, stopTimeout = 5, resetLog = false }
local RESERVED = { status = true, restart = true }

local services = {}
local entries = {}
local halting = false

local function log(msg)
    polaris.log("services: " .. msg)
end

local function readAll(path)
    local file, reason = filesystem.open(path, "r")
    if not file then return nil, reason end

    local chunks = {}
    for chunk in function() return file:read(math.huge) end do
        chunks[#chunks + 1] = chunk
    end
    file:close()
    return table.concat(chunks)
end

-- Kernel space
local function compile(path)
    local src, reason = readAll(path)
    if not src then return nil, reason end
    return load(src, "=" .. path, "bt", kernelEnv)
end

local function loadConfig(path)
    if not filesystem.exists(path) then return {} end

    local fn, err = compile(path)
    if not fn then return nil, err end

    local ok, cfg = pcall(fn)
    if not ok then return nil, cfg end
    return cfg
end

local function validate(name, cfg)
    if type(cfg) ~= "table" then return nil, "config must return a table" end

    local c = {}
    for key, default in pairs(DEFAULTS) do
        if cfg[key] == nil then c[key] = default else c[key] = cfg[key] end
    end
    c.label = cfg.label == nil and name or cfg.label

    if type(c.label) ~= "string" or c.label == "" then return nil, "bad label" end
    if type(c.priority) ~= "number" or c.priority % 1 ~= 0 or c.priority < 0 or c.priority > 255 then
        return nil, "priority must be an integer 0-255"
    end
    if c.onExit ~= "stop" and c.onExit ~= "restart" and type(c.onExit) ~= "function" then
        return nil, "onExit must be \"stop\", \"restart\" or a function"
    end
    if type(c.autostart) ~= "boolean" then return nil, "autostart must be a boolean" end
    if type(c.restartDelay) ~= "number" or c.restartDelay < 0 then return nil, "bad restartDelay" end
    if type(c.stopTimeout) ~= "number" or c.stopTimeout <= 0 then return nil, "bad stopTimeout" end
    if type(c.resetLog) ~= "boolean" then return nil, "resetLog must be a boolean" end
    return c
end

-- Is it a good service? I hope
local function loadModule(path)
    local fn, err = compile(path)
    if not fn then return nil, err end

    local ok, mod = pcall(fn)
    if not ok then return nil, mod end

    if type(mod) ~= "table" then
        return nil, "init.lua must return a table"
    end
    if type(mod.start) ~= "function" then
        return nil, "service table must have a start() function"
    end

    for key in pairs(mod) do
        if RESERVED[key] then
            return nil, "service table uses reserved name: " .. key
        end
    end

    return mod
end

local function register(name)
    local dir = filesystem.concat(ROOT, name .. ".d")
    local init = filesystem.concat(dir, "init.lua")
    local conf = filesystem.concat(dir, "config.lua")

    if not filesystem.exists(init) then
        return log(name .. ": no init.lua")
    end

    local cfg, err = loadConfig(conf)
    if err then return log(name .. ": " .. tostring(err)) end

    local c, reason = validate(name, cfg)
    if not c then return log(name .. ": " .. reason) end

    entries[name] = {
        name = name,
        init = init,
        cfg = c,
        ring = ring.new(polaris.config["service_log_buffer_length"] or 64),
        starts = 0,
        stopping = false,
        restarting = false,
        mod = nil,
    }
end

local function sorted()
    local out = {}
    for _, e in pairs(entries) do out[#out + 1] = e end
    table.sort(out, function(a, b)
        if a.cfg.priority ~= b.cfg.priority then return a.cfg.priority > b.cfg.priority end
        return a.name < b.name
    end)
    return out
end

local function describe(success, reason)
    if not success then
        return reason == "killed" and "killed" or "error: " .. tostring(reason)
    end
    if reason == "cancelled" then return "cancelled" end
    if type(reason) == "number" then return "exit code " .. reason end
    return "returned"
end

-- Hey something died! Dont you yield here
local function exited(e, pid, success, reason)
    process.destroy(pid)

    if e.killTimer then
        event.cancel(e.killTimer)
        e.killTimer = nil
    end

    local requested, restart = e.stopping, e.restarting
    e.pid, e.stopping, e.restarting = nil, false, false
    e.stoppedAt = computer.uptime()
    e.last = { success = success, reason = reason, requested = requested, text = describe(success, reason) }
    e.ring:push("svc", "stopped: " .. e.last.text)

    if halting then return end

    local mode = e.cfg.onExit
    if type(mode) == "function" then
        local ok, err = pcall(mode, { name = e.name, success = success, reason = reason, requested = requested })
        if not ok then e.ring:push("svc", "onExit failed: " .. tostring(err)) end
    elseif mode == "restart" and not requested then
        services.start(e.name, e.cfg.restartDelay)
    end

    -- Restart?
    if restart and not e.pid and not e.timer then
        services.start(e.name)
    end
end

function services.start(name, delay)
    local e = entries[name]
    if not e then return nil, "no such service: " .. tostring(name) end
    if halting then return nil, "system is halting" end
    if e.pid then return nil, "already running" end

    if e.timer then
        event.cancel(e.timer)
        e.timer = nil
    end
    if delay and delay > 0 then
        e.timer = event.timer(delay, function()
            e.timer = nil
            services.start(name)
        end, 1)
        return true
    end

    if e.cfg.resetLog then
        e.ring = ring.new(polaris.config["service_log_buffer_length"] or 64)
    end

    -- Reload so restart picks up changes
    local cfg, cfgErr = loadConfig(filesystem.concat(ROOT, name .. ".d", "config.lua"))
    if cfgErr then
        e.ring:push("svc", "start failed (config): " .. tostring(cfgErr))
        return nil, cfgErr
    end
    local c, reason = validate(name, cfg)
    if not c then
        e.ring:push("svc", "start failed (config): " .. reason)
        return nil, reason
    end
    e.cfg = c

    local mod, err = loadModule(e.init)
    if not mod then
        e.ring:push("svc", "start failed (load): " .. tostring(err))
        return nil, err
    end
    e.mod = mod

    local pid
    pid = process.spawn(function()
        local ok, failure = xpcall(mod.start, function(msg)
            process.writeError(debug.traceback(tostring(msg), 2), "\n")
            return msg
        end, e.name)
        if not ok then error(failure, 0) end
    end, {
        label = e.cfg.label,
        ppid = false, -- kernel
        gid = process.GID.SVC,
        reserved = true,
        onExit = function(success, reason)
            exited(e, pid, success, reason)
        end,
    })

    env.set(pid, kernelEnv)
    process.create(pid, polaris.io.newStream(), e.ring:stream("stdout"), e.ring:stream("stderr"))

    e.pid, e.startedAt = pid, computer.uptime()
    e.starts = e.starts + 1
    e.ring:push("svc", "started (pid " .. pid .. ")")
    return true
end

-- Ask nicely then dont to stop a service
function services.stop(name)
    local e = entries[name]
    if not e then return nil, "no such service: " .. tostring(name) end

    if e.timer then
        event.cancel(e.timer)
        e.timer = nil
        return true
    end

    if not e.pid then return nil, "not running" end
    if e.stopping then return true end

    local pid = e.pid
    e.stopping = true

    if e.mod and type(e.mod.stop) == "function" then
        local ok, err = pcall(e.mod.stop, e.name)
        if not ok then
            e.ring:push("svc", "stop() error: " .. tostring(err))
        end
    end

    process.cancel(pid)
    e.killTimer = event.timer(e.cfg.stopTimeout, function()
        e.killTimer = nil
        if e.pid == pid then
            process.kill(pid)
        end
    end, 1)

    return true
end

function services.restart(name)
    local e = entries[name]
    if not e then return nil, "no such service: " .. tostring(name) end
    if not e.pid then return services.start(name) end

    e.restarting = true
    return services.stop(name)
end

-- Run a function from the thing, like changing a config value
function services.call(name, func, ...)
    local e = entries[name]
    if not e then return nil, "no such service: " .. tostring(name) end
    if RESERVED[func] then return nil, "'" .. func .. "' is reserved" end

    if not e.mod then return nil, "service not loaded" end

    local fn = e.mod[func]
    if type(fn) ~= "function" then
        return nil, "no such function '" .. func .. "' in service '" .. name .. "'"
    end

    local results = table.pack(pcall(fn, ...))
    local ok = table.remove(results, 1)
    results.n = results.n - 1

    if not ok then
        local err = tostring(results[1])
        e.ring:push("svc", func .. "() error: " .. err)
        return nil, err
    end

    local parts = {}
    for i = 1, results.n do parts[i] = tostring(results[i]) end
    if #parts > 0 then
        e.ring:push("svc", func .. "() : " .. table.concat(parts, ", "))
    else
        e.ring:push("svc", func .. "()")
    end

    return table.unpack(results, 1, results.n)
end

function services.list()
    local out = {}
    for _, e in ipairs(sorted()) do out[#out + 1] = e.name end
    return out
end

function services.status(name)
    local e = entries[name]
    if not e then return nil, "no such service: " .. tostring(name) end

    local state = "stopped"
    if e.pid then
        state = e.stopping and "stopping" or "running"
    elseif e.timer then
        state = "restarting"
    elseif e.starts == 0 then
        state = "never started"
    end

    -- Exported functions
    local exports = {}
    if e.mod then
        for k, v in pairs(e.mod) do
            if type(v) == "function" and k ~= "start" and k ~= "stop" and not RESERVED[k] then
                exports[#exports + 1] = k
            end
        end
        table.sort(exports)
    end

    return {
        name = e.name,
        label = e.cfg.label,
        exec = e.init,
        priority = e.cfg.priority,
        onExit = type(e.cfg.onExit) == "function" and "custom" or e.cfg.onExit,
        autostart = e.cfg.autostart,
        state = state,
        starts = e.starts,
        startedAt = e.startedAt,
        stoppedAt = e.stoppedAt,
        last = e.last,
        proc = e.pid and process.get(e.pid) or nil,
        exports = exports,
    }
end

function services.log(name)
    local e = entries[name]
    if not e then return nil, "no such service: " .. tostring(name) end
    return e.ring:entries()
end

function services.load()
    if not filesystem.isDirectory(ROOT) then
        return log(ROOT .. " not found")
    end

    for entry in filesystem.list(ROOT) do
        local name = entry:match("^(.+)%.d/?$")
        if name and not entries[name] then register(name) end
    end
    log(#services.list() .. " registered")
end

function services.boot()
    services.load()
    for _, e in ipairs(sorted()) do
        if e.cfg.autostart then
            local ok, err = services.start(e.name)
            if not ok then log(e.name .. ": " .. tostring(err)) end
        end
    end
end

function services.halt()
    halting = true
end

return services
