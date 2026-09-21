-- /bin/error.lua
io.stderr:write("Error\n")
io.flush()
error("Error catch")