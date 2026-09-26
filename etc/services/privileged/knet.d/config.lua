-- /etc/services/privileged/knet.d/config.lua
return {
    label = "knetd",         -- yay minitel port. "KPS net"
    priority = 200,         -- I am early
    onExit = "stop",
    autostart = false,
    restartDelay = 5,
    stopTimeout = 5,
}