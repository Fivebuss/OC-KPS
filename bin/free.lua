-- /bin/free.lua
local total = computer.totalMemory()
local max = 0
max = math.max(max, computer.freeMemory())
io.write(string.format("Total%12d\nUsed%13d\nFree%13d\n", total, total - max, max))