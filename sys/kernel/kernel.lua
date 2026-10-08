-- Main kernel thread

assert(polaris.scheduler, "System failure: Kernel: scheduler not initialized")

local scheduler = polaris.scheduler


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

    -- Pcall stuff
    local vals, n = {}, packed.n - 1
    for i = 1, n do
        vals[i] = packed[i + 1]
    end

    return { ok = true, n = n, vals = vals }
end

local function kernelProcess()
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
