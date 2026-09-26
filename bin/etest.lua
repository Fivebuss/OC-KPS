local computer = require("computer")

local event = require("event")

io.write("waiting...\n")

local sig, addr, char, code = event.pull("key_down")

io.write("got: " .. tostring(sig) .. "\n")
io.write("char: " .. tostring(char) .. "\n")
io.write("code: " .. tostring(code) .. "\n")