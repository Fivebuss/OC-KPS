-- Polaris syscalls
local computer = require("computer")
local event = require("event")

local function prepareHalt(signal, keepUid)
    -- Hey guys, prepare to die
    event.push(tostring(signal))
    polaris.services.halt()

    local selfUid = polaris.scheduler.activeThread()
    local kernelUid = polaris.scheduler.kernelProcess
    local keep = keepUid or selfUid

    -- Send out INT
    local scheduler = polaris.scheduler
    for _, info in ipairs(scheduler.list()) do
        local uid = info.cid
        if uid ~= kernelUid and uid ~= keep then
            scheduler.signal(uid, scheduler.SIG.INT)
        end
    end

    -- Il be nice, you can have some time to shutdown
    local deadline = computer.uptime() + 2
    while computer.uptime() < deadline and scheduler.threadCount() > 2 do
        -- threadCount > 2: kernel + caller still alive, wait for the rest
        coroutine.yield()
    end
    -- Not all the time though
    scheduler.killAll(keep)
    scheduler.cleanup(event)
    scheduler.deinit(event, scheduler.handler)
end

local function call(syscall, ...)
    local scheduler = polaris.scheduler
    local kernelUid = scheduler.kernelProcess

    if not kernelUid then
        error("System failure: kernel process not running: " .. tostring(syscall))
    end

    local callerUid = scheduler.activeThread()

    if not callerUid then
        error(
            "syscall.call must be used from inside a scheduler controlled coroutine " ..
            "(no caller uid)"
        )
    end

    -- Calls made by the kernel itself dont care about ipc
    if callerUid == kernelUid then
        local handler = polaris.syscalls[syscall]

        if not handler then
            error("Unknown syscall: " .. tostring(syscall))
        end

        return handler(nil, ...)
    end

    local args = table.pack(...)

    scheduler.sendData(kernelUid, {
        caller = callerUid,
        syscall = syscall,
        args = args,
        n = args.n,
    })

    local reply = scheduler.waitForInput()

    if not reply or type(reply) ~= "table" then
        error(
            "Syscall: " .. tostring(syscall) ..
            " failed: no reply from kernel UID " .. tostring(kernelUid),
            2
        )
    end

    if not reply.ok then
        error(reply.err, 0)
    end

    return table.unpack(reply.vals, 1, reply.n)
end

-- Syscalls themselves
polaris.syscalls.shutdown = function(ctx)
    prepareHalt("shutdown", ctx and ctx.caller)
    computer.shutdown()
end

polaris.syscalls.reboot = function(ctx)
    prepareHalt("shutdown", ctx and ctx.caller)
    computer.shutdown(1)
end

-- Runs a file in a managed _ENV
polaris.syscalls.execute = function(ctx, path, env)
    local caller = ctx and ctx.caller

    if env == nil then
        if not caller then
            error("execute: no env provided", 0)
        end
        env = polaris.env.forProcess(caller)
    end

    local filesystem = require("filesystem")
    local file, reason = filesystem.open(path, "r")
    if not file then
        return nil, reason or ("cannot open " .. tostring(path))
    end

    local buffer = {}
    while true do
        local chunk = file:read(math.maxinteger or math.huge)
        if not chunk then break end
        buffer[#buffer + 1] = chunk
    end
    file:close()

    local fn, err = env.load(table.concat(buffer), "=" .. path, "bt")
    if not fn then
        return nil, err
    end

    return fn()
end

-- Fancy
polaris.syscalls.service = function(_, action, name)
    if action ~= "start" and action ~= "stop" and action ~= "restart" then
        error("service: unknown action '" .. tostring(action) .. "'", 0)
    end
    return polaris.services[action](name)
end

return call
