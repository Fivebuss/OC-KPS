-- /lib/syslog.lua
-- syslog("function or name", level, "message")
local process = require("process")

local syslog = {}
syslog.emergency = 0
syslog.alert = 1
syslog.critical = 2
syslog.error = 3
syslog.warning = 4
syslog.notice = 5
syslog.info = 6
syslog.debug = 7

setmetatable(syslog, {
    __call = function(_, func, level, message)
        local cmd = process.get(process.activeThread()).cmd
        level = level or syslog.info
        computer.pushSignal("syslog", cmd, func, level, message)
    end
})

return syslog
