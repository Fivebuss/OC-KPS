local computer = require("computer")

local event = require("event")

io.write("waiting...\n")

local out = event.pull("beacon")

io.write(out)