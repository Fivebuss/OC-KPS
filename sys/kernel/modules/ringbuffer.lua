-- /sys/kernel/modules/ringbuffer.lua
-- Its just a ring buffer thing but can be be used multiple times
-- Realistically shouldnt be a kernel module but who cares

local computer = require("computer")

local ring = {}
ring.__index = ring

function ring.new(capacity)
    checkArg(1, capacity, "number")
    return setmetatable({ lines = {}, head = 1, count = 0, capacity = capacity }, ring)
end

function ring:push(tag, text)
    self.lines[self.head] = string.format("[%.3f] [%s] : %s", computer.uptime(), tag, text)
    self.head = self.head % self.capacity + 1
    self.count = math.min(self.count + 1, self.capacity)
end

-- Oldest first
function ring:entries()
    local out = {}
    local start = self.count < self.capacity and 1 or self.head
    for i = 0, self.count - 1 do
        out[#out + 1] = self.lines[(start - 1 + i) % self.capacity + 1]
    end
    return out
end

-- Line based
function ring:stream(tag)
    local buffer = self
    local partial = ""
    local ringBuffer = {}

    function ringBuffer:write(...)
        partial = (partial .. table.concat({ ... })):gsub("([^\n]*)\n", function(line)
            buffer:push(tag, line)
            return ""
        end)
        return true
    end

    function ringBuffer:flush() return true end

    function ringBuffer:close()
        if partial ~= "" then
            buffer:push(tag, partial)
            partial = ""
        end
        return true
    end

    return ringBuffer
end

return ring