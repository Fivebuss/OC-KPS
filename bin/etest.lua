local computer = require("computer")
local event = require("sys.kernel.modules.event")

io.write("before\n")

local start = computer.uptime()

event.pull(2)

io.write("after 2 seconds\n")