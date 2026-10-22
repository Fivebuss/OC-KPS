-- /sys/kernel/modules/env.lua
--[[
Each process gets their own _ENV! yay

e.load(chunk, chunkname, mode, givenEnv): Load but it hopefully cant fail
e.error(msg) / e.assert(v, msg, ...): Returns error, yeah it just xpcalls

env.new(base):              inherits from base via __index, does NOT copy globals
env.forProcess(pid, parentEnv):   gets existing, or makes one (inheriting parentEnv, else fresh _G copy)
env.get(pid):               see above
env.set(pid, e):            modifies a pid's _ENV
env.destroy(pid):           gets rid of a env thing
env.current():              the current one when used inside a process

--]]

local env = {}

-- the pid env table
local owners = {}

local function process()
    return polaris.process
end

-- should probably save this
local realLoad = load

-- Modifies load, error and assert
local function installOverrides(e, base)
    -- Environment variable stuff
    -- inherit parent env vars as starting point, then give child its own copy
    e.env = e.env or {}

    e.getenv = function(key)
        checkArg(1, key, "string")
        return e.env[key]
    end

    e.setenv = function(key, value)
        checkArg(1, key, "string")
        e.env[key] = value
    end

    e.getall = function()
        local result = {}
        for k, v in pairs(e.env) do
            result[k] = v
        end
        return result
    end

    e.error = function(msg, level)
        error(msg, (level or 1) + 1)
    end

    e.assert = function(v, msg, ...)
        if v then
            return v, msg, ...
        end

        e.error(msg == nil and "assertion failed!" or msg, 1)
    end

    e.load = function(chunk, chunkname, mode, givenEnv)
        local targetEnv = givenEnv or e
        return realLoad(chunk, chunkname, mode or "bt", targetEnv)
    end
end

-- Copies _G then patches inside a _ENV
function env.new(base)
    checkArg(1, base, "table", "nil")
    base = base or _G

    local e = {}

    setmetatable(e, { __index = base, __newindex = rawset })

    -- __index trick to save ram
    e.env = {}
    if base.env and type(base.env) == "table" then
        for k, v in pairs(base.env) do
            e.env[k] = v
        end
    end

    e._G = e
    e._ENV = e

    installOverrides(e, base)

    return e
end

-- Gets or makes one for a pid. If missing, inherits parentEnv so children are in the same house
function env.forProcess(pid, parentEnv)
    checkArg(1, pid, "number")

    local e = owners[pid]
    if not e then
        e = parentEnv and env.new(parentEnv) or env.new()
        owners[pid] = e
    end
    return e
end

function env.get(pid)
    checkArg(1, pid, "number")
    return owners[pid]
end

function env.set(pid, e)
    checkArg(1, pid, "number")
    checkArg(2, e, "table")
    owners[pid] = e
    return e
end

function env.destroy(pid)
    checkArg(1, pid, "number")
    owners[pid] = nil
end

-- Current one
function env.current()
    local p = process()
    local info = p and p.self()
    local pid = info and info.pid

    if not pid then
        return _G
    end

    return env.forProcess(pid)
end

return env