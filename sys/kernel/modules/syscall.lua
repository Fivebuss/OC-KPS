-- Polaris syscalls
local computer = require("computer")
local event = require("sys.kernel.modules.event")

local function prepareHalt(signal, keepUid)
    event.push(tostring(signal))

    local selfUid = polaris.scheduler.currentThread()
    polaris.scheduler.killAll(keepUid or selfUid)
    polaris.scheduler.cleanup(event)
    polaris.scheduler.deinit(event, polaris.scheduler.handler)
end

local function call(syscall, ...)
    local scheduler = polaris.scheduler
    local kernelUid = scheduler.kernelProcess

    if not kernelUid then
        error("System failure: kernel process not running: " .. tostring(syscall))
    end

    local callerUid = scheduler.currentThread()

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

return call