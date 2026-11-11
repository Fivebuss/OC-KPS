-- /bin/gc.lua
-- Borrowed from openOS
local event = require("event")
local total = computer.totalMemory()
local max = 0
max = math.max(max, computer.freeMemory())

io.write(string.format("Triggering GC\nPre--:\nTotal%12d\nUsed%13d\nFree%13d\n", total, total - max, max))

for _=1,10 do
    max = math.max(max, computer.freeMemory())
    computer.pullSignal(0)
end

io.write(string.format("Post--:\nUsed%13d\nFree%13d\n", total - max, max))
