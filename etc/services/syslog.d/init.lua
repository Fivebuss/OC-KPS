-- /etc/services/syslog.d/init.lua
-- Poor mans syslogd. No, it is not networked but its easy enough to write a service for that
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")
local process = polaris.process

local svc = {}

local listeners = {}

local LOG_PATH = "/sys/log"
local DEBUG_LEVEL = 7
local logFile = nil

-- syslog("function or name", level, "message")
local function logLine(cmd, func, level, message)
    if not logFile then
        return
    end

    local ok, err = logFile:write(string.format("%.2f\t%s\t%s\t%s\t%s\n",
        computer.uptime(),
        tostring(cmd),
        tostring(func),
        tostring(level),
        tostring(message)))

    if not ok then
        process.write("syslogd: write log failure: " .. tostring(err) .. "\n")
    end
end

local function onSyslog(_, cmd, func, level, message)
    level = tonumber(level) or 6
    func = func or "main"

    if level == DEBUG_LEVEL then
        if not (polaris.config and polaris.config["debug"] == true) then
            return
        end
    end

    logLine(cmd, func, level, message)

    -- emergency! I will log to kernel then
    if level == 0 then
        computer.beep(2000)
        computer.beep(2000)
        polaris.log("syslogd: " .. serialization.serialize({
            uptime = computer.uptime(),
            exec = tostring(cmd),
            func = tostring(func),
            level = level,
            message = tostring(message),
        }))
        -- alert / critical
    elseif level == 1 or level == 2 then
        computer.beep(2000)
    end
end

-- Resets file and just does it
function svc.start(name)
    local err
    logFile, err = filesystem.open(LOG_PATH, "wb")

    if not logFile then
        process.write("syslogd: open log failure: " .. tostring(err) .. "\n")
        return false
    end
    process.write(name, ": opened log file " .. LOG_PATH .. "\n")

    listeners["syslog"] = onSyslog
    event.listen("syslog", onSyslog)

    process.write(name, ": started, listening for syslog signals\n")
    logLine("syslogd", "svc.start", 6, "Syslog started with PID " .. process.self().pid)

    local input = process.waitForInput()
    if input == nil then input = "stopped" end

    process.write(name, ": exited: " .. tostring(input) .. "\n")

    svc.stop(name)

    return true
end

function svc.stop(name)
    for evname, fn in pairs(listeners) do
        event.ignore(evname, fn)
        listeners[evname] = nil
    end

    if logFile then
        logLine(name, "svc.stop", 5, "Syslog exited")
        logFile:close()
        logFile = nil
    end

    return true
end

return svc
