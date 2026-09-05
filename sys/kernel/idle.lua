-- Because in OC, when init returns it exits. And a generic loop isnt a good thing
-- So we do this nonsense


assert(polaris.scheduler, "System failure: Kernel: process not initialized")

local scheduler = polaris.scheduler

local function idle()
    while true do
        local msg = scheduler.waitForInput()

        if msg == "Halt" then
            computer.beep(2000)
            return
        end
    end
end

local function onExit(success, reason)
    if success then
        polaris.call("shutdown")
    end
end

scheduler.idle = scheduler.spawn(idle, onExit, "idle")

return scheduler.idle