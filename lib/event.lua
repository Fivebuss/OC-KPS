-- /lib/event.lua

local event = require("sys.kernel.modules.event_internals")
local scheduler = require("sys.kernel.modules.scheduler")

local M = {}

local computer = require("computer")

local function createPlainFilter(name, ...)
    local filter = table.pack(...)

    if name == nil and filter.n == 0 then
        return nil
    end

    return function(...)
        local signal = table.pack(...)

        if name and not (
            type(signal[1]) == "string"
            and signal[1]:match(name)
        ) then
            return false
        end

        for i = 1, filter.n do
            if filter[i] ~= nil
               and filter[i] ~= signal[i + 1] then
                return false
            end
        end

        return true
    end
end

local function createMultipleFilter(...)
    local filter = table.pack(...)

    if filter.n == 0 then
        return nil
    end

    return function(...)
        local signal = table.pack(...)

        if type(signal[1]) ~= "string" then
            return false
        end

        for i = 1, filter.n do
            if filter[i] ~= nil
               and signal[1]:match(filter[i]) then
                return true
            end
        end

        return false
    end
end

-- okay you can use this
M.register = event.register
M.listen = event.listen
M.ignore = event.ignore

M.timer = event.timer
M.cancel = event.cancel

M.skip = event.skip
M.onError = event.onError

M.push = event.push
M.pushSignal = event.pushSignal

M.handlers = event.handlers
M.getHandlers = event.getHandlers

-- time
function M.pull(...)
    local args = table.pack(...)

    if type(args[1]) == "string" then
        return M.pullFiltered(
            createPlainFilter(...)
        )
    end

    checkArg(1, args[1], "number", "nil")
    checkArg(2, args[2], "string", "nil")

    return M.pullFiltered(
        args[1],
        createPlainFilter(select(2, ...))
    )
end

function M.pullFiltered(...)
    local args = table.pack(...)

    local seconds
    local filter

    if type(args[1]) == "function" then
        seconds = nil
        filter = args[1]
    else
        checkArg(1, args[1], "number", "nil")
        checkArg(2, args[2], "function", "nil")

        seconds = args[1]
        filter = args[2]
    end

    if not filter then
        filter = function()
            return true
        end
    end

    return scheduler.waitForEvent(seconds, filter)
end

function M.pullMultiple(...)
    local seconds
    local args

    if type(...) == "number" then
        seconds = ...
        args = table.pack(select(2, ...))

        for i = 1, args.n do
            checkArg(
                i + 1,
                args[i],
                "string",
                "nil"
            )
        end
    else
        args = table.pack(...)

        for i = 1, args.n do
            checkArg(
                i,
                args[i],
                "string",
                "nil"
            )
        end
    end

    return M.pullFiltered(
        seconds,
        createMultipleFilter(
            table.unpack(args, 1, args.n)
        )
    )
end

return M