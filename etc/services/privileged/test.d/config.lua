-- restartDelay, stopTimeout
return {
    label = "Example Service", -- The label in process table
    priority = 255, -- Priority 0->255, higher starts first
    onExit = "restart", -- "stop"(default) "restart" or a function, kindly dont yield during a custom one, bad idea
    autostart = false, -- Duh
    restartDelay = 5, -- Delay seconds between restarts for onExit
    stopTimeout = 1, -- Default five, seconds from when cancel becomes kill for stopping a service
}