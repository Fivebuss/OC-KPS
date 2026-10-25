-- /etc/services/privileged/knetd.d/config.lua
-- See /etc/network/knetd.cfg
return {
    label = "knetd",
    priority = 200,
    onExit = "stop",
    autostart = true,
    restartDelay = 5,
    stopTimeout = 5,
    resetLog = false,
}
