-- Borrowed from openOS
local event = require("event")
local total = computer.totalMemory()
local max = 0
local args = {...}

for _=1,40 do
    max = math.max(max, computer.freeMemory())
    event.pull(0)
end

io.write(string.format("Total%12d\nUsed%13d\nFree%13d\n", total, total - max, max))