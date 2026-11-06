-- Main kernel thread

assert(polaris.scheduler, "System failure: Kernel: scheduler not initialized")

local scheduler = polaris.scheduler
local event = require("event_internals")


-- Actual syscalls
local function dispatch(req)
    local handler = polaris.syscalls[req.syscall]

    if not handler then
        return { ok = false, err = "Unknown syscall: " .. tostring(req.syscall) }
    end

    local packed = table.pack(pcall(handler, { caller = req.caller }, table.unpack(req.args, 1, req.n)))
    local ok = packed[1]

    if not ok then
        return { ok = false, err = packed[2] }
    end

    -- Do the thing
    local vals, n = {}, packed.n - 1
    for i = 1, n do
        vals[i] = packed[i + 1]
    end

    return { ok = true, n = n, vals = vals }
end

-- Sysrq is not magic

local sysrq = {}
sysrq.actions = {}
sysrq.active = false
sysrq.startedAt = 0
sysrq.timeout = 5

function sysrq.register(char, fn)
    sysrq.actions[char] = fn
end

polaris.sysrq = sysrq

local function sysrqKeyHandler(_, _, char, code, _)
    local now = computer.uptime()

    -- KP Enter
    if code == 156 then
        if not sysrq.active then
            sysrq.active = true
            sysrq.startedAt = now
            computer.beep(1000)
        else
            sysrq.startedAt = now
        end

        return
    end

    if not sysrq.active then
        return
    end

    if now - sysrq.startedAt >= sysrq.timeout then
        sysrq.active = false
        sysrq.startedAt = 0
        computer.beep(1000)
        return
    end

    -- Execute action
    local action = sysrq.actions[char]

    if action then
        pcall(action)
    end

    sysrq.active = false
    sysrq.startedAt = 0
end

local sysrqKeyId = event.listen("key_down", sysrqKeyHandler)

local function kernelProcess()
    if _VERSION == "Lua 5.3" then
        polaris.log("Warning: Lua 5.3 machine memory usage will be higher\nRecommend switch to Lua 5.4")
    end
    while true do
        local msg = scheduler.waitForInput()

        if msg == "Halt" then
            computer.beep(2000)
            return
        elseif type(msg) == "table" and msg.syscall then
            -- {caller = uid, syscall = name, args = {...}, n = argCount}
            local req = msg
            local reply = dispatch(req)

            if req.caller then
                scheduler.sendData(req.caller, reply)
            end
        end
    end
end

local function onExit(success, reason)
    if success then
        local handler = polaris.syscalls["shutdown"]
        if handler then handler() end
    end
end

scheduler.kernelProcess = scheduler.spawn(kernelProcess, onExit, "polaris")

return scheduler.kernelProcess
