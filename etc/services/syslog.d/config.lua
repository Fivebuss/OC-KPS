-- /etc/services/privileged/syslog.d/config.lua
return {
    label = "syslogd",
    priority = 5,
    onExit = "stop",
    autostart = true,
    restartDelay = 2,
    stopTimeout = 3,
    resetLog = false,
}