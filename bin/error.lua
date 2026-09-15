-- /bin/error.lua
io.writeError("Hey! I errored!\n")
io.stderr:write("I errored but I called it with stream object!\n")
error("I errored here too")
assert(false, "If you see this then something went badly")