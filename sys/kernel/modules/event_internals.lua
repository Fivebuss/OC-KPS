-- /sys/kernel/modules/event_internals.lua

local computer = require("computer")
local keyboard = require("keyboard")

local event = {}
local handlers = {}

local lastInterrupt = -math.huge
local skipSignalType = nil

event.handlers = handlers

function event.getHandlers()
    return handlers
end

function event.register(key, callback, interval, times, opt_handlers)
    local target = opt_handlers or handlers

    local handler = {
        key = key,
        times = times or 1,
        callback = callback,
        interval = interval or math.huge,
    }

    handler.timeout = computer.uptime() + handler.interval

    local id = 0
    repeat
        id = id + 1
    until not target[id]

    target[id] = handler
    return id
end

function event.cancel(timerId)
    checkArg(1, timerId, "number")

    if handlers[timerId] then
        handlers[timerId] = nil
        return true
    end

    return false
end

function event.listen(name, callback)
    checkArg(1, name, "string")
    checkArg(2, callback, "function")

    for _, handler in pairs(handlers) do
        if handler.key == name and handler.callback == callback then
            return false
        end
    end

    return event.register(name, callback, math.huge, math.huge)
end

function event.ignore(name, callback)
    checkArg(1, name, "string")
    checkArg(2, callback, "function")

    for id, handler in pairs(handlers) do
        if handler.key == name and handler.callback == callback then
            handlers[id] = nil
            return true
        end
    end

    return false
end

function event.timer(interval, callback, times)
    checkArg(1, interval, "number")
    checkArg(2, callback, "function")
    checkArg(3, times, "number", "nil")

    return event.register(
        false,
        callback,
        interval,
        times or math.huge
    )
end

function event.skip(signalType)
    skipSignalType = signalType
end

function event.onError(message)
    local log = io.open("/tmp/event.log", "a")

    if log then
        pcall(log.write, log, tostring(message), "\n")
        log:close()
    end
end

event.push = computer.pushSignal
event.pushSignal = event.push

-- Bla bla pullsignal

local _pullSignal = computer.pullSignal

function event.pullSignal(seconds)
    checkArg(1, seconds, "number", "nil")

    seconds = seconds or math.huge

    local uptime = computer.uptime
    local deadline = uptime() + seconds

    repeat
        local interrupting =
            uptime() - lastInterrupt > 1 and
            keyboard.isControlDown() and
            keyboard.isKeyDown(keyboard.keys.c)

        if interrupting then
            lastInterrupt = uptime()

            if keyboard.isAltDown() then
                -- Keep your existing Ctrl+Alt+C behavior if desired.
                local uid =
                    polaris and
                    polaris.scheduler and
                    polaris.scheduler.activeThread()

                if uid then
                    polaris.scheduler.signal(
                        uid,
                        polaris.scheduler.SIG.INT
                    )
                end

                return
            end

            event.push("interrupted", lastInterrupt)
        end

        local closest = deadline

        for _, handler in pairs(handlers) do
            closest = math.min(handler.timeout, closest)
        end

        local event_data = table.pack(
            _pullSignal(closest - uptime())
        )

        local signal = event_data[1]

        -- Fix
        local copy = {}

        for id, handler in pairs(handlers) do
            copy[id] = handler
        end

        for id, handler in pairs(copy) do
            if
                (handler.key == nil or handler.key == signal)
                or uptime() >= handler.timeout
            then
                handler.times = handler.times - 1
                handler.timeout =
                    handler.timeout + handler.interval

                if
                    handler.times <= 0
                    and handlers[id] == handler
                then
                    handlers[id] = nil
                end

                local result, message = pcall(
                    handler.callback,
                    table.unpack(
                        event_data,
                        1,
                        event_data.n
                    )
                )

                if not result then
                    pcall(event.onError, message)
                elseif message == false and handlers[id] == handler then
                    handlers[id] = nil
                end
            end
        end

        if signal then
            if signal == skipSignalType then
                skipSignalType = nil
            else
                return table.unpack(
                    event_data,
                    1,
                    event_data.n
                )
            end
        end

    until uptime() >= deadline
end

return event