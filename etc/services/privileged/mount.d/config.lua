-- /etc/services/privileged/mount.d/config.lua
return {
    label = "mountd",
    priority = 200,
    onExit = "stop",
    autostart = true,
    restartDelay = 2,
    stopTimeout = 3,
    resetLog = false,
}