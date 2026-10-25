-- /usr/lib/network/ipc.lua
-- Like syscalls work

local M = {}

local daemonPid = nil

local nextId = 0

function M.setDaemon(pid)
    daemonPid = pid
    return true
end

function M.clearDaemon()
    daemonPid = nil
    return true
end

function M.getDaemon()
    if daemonPid == nil then
        return nil
    end
    local process = polaris.process
    if not process or not process.exists(daemonPid) then
        daemonPid = nil
        return nil
    end
    return daemonPid
end

function M.currentPid()
    local process = polaris.process
    if not process then return nil end
    local ok, info = pcall(process.self)
    if ok and type(info) == "table" and info.pid then
        return info.pid
    end
    return nil
end

function M.newId()
    nextId = nextId + 1
    return nextId
end

function M.request(op, args)
    local msg = {
        network = true,
        kind = "request",
        id = M.newId(),
        pid = M.currentPid(),
        op = op,
        args = args or {},
    }
    return msg
end

-- Go to a queue though
function M.send(pid, message)
    local process = polaris.process
    if not process or type(pid) ~= "number" or message == nil then
        return nil, "invalid ipc send"
    end
    if not process.exists(pid) then
        return nil, "process " .. tostring(pid) .. " is gone"
    end
    local ok = process.send(pid, message)
    if not ok then
        -- and process disappeared
        return nil, "process " .. tostring(pid) .. " is not accepting messages"
    end
    return true
end

function M.isSignal(value)
    local process = polaris.process
    if not process then return false end
    return process.isSignal(value) or false
end

-- blocking until we get something useful
function M.wait(filter, timeout)
    local process = polaris.process
    if not process then
        return nil, "no process module"
    end

    local pid = M.currentPid()
    if pid == nil then
        return nil, "ipc.wait must be called inside a process"
    end

    local timerId = nil
    local timerFired = false

    local function fireTimeout()
        timerId = nil
        timerFired = true
        process.send(pid, { network = true, kind = "wake" })
    end

    if type(timeout) == "number" and timeout > 0 then
        timerId = require("event").timer(timeout, fireTimeout, 1)
    end

    while true do -- gross
        local value = process.waitForInput()

        if M.isSignal(value) then
            if timerId then
                require("event").cancel(timerId)
                timerId = nil
            end
            return nil, value
        end

        if timerFired and type(value) == "table" and value.network and value.kind == "wake" then
            return nil, "timeout"
        end

        local ok, matched = pcall(filter, value)
        if ok and matched then
            if timerId then
                require("event").cancel(timerId)
                timerId = nil
            end
            return value, nil
        end
    end
end

-- RPC time
function M.call(op, args, timeout)
    local daemon = M.getDaemon()
    if not daemon then
        return nil, "knetd not running"
    end
    local req = M.request(op, args)
    local ok = M.send(daemon, req)
    if not ok then
        M.clearDaemon()
        return nil, "knetd not running"
    end
    local reply = M.wait(function(value)
        return type(value) == "table" and value.network and
            value.kind == "reply" and value.id == req.id
    end, timeout or 5)
    if reply == nil then
        return nil, "timeout"
    end
    if not reply.ok then
        return nil, reply.err or "request failed"
    end
    return reply, nil
end

return M
