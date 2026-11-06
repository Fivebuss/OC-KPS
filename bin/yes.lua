-- /bin/yes.lua
-- yes man
local process = polaris.process

local args = { ... }

local modeChunk = false
local modeNoNewline = false
local str = "y"

-- -c coroutine yields for one character, as batching writes is a lazy trick for performance
-- But you may not want it
local i = 1
while i <= #args do
    local a = args[i]
    if a == "-c" then
        modeChunk = true
    elseif a == "-n" then
        modeNoNewline = true
    else
        str = a
    end
    i = i + 1
end

local suffix = modeNoNewline and "" or "\n"
local out = str .. suffix

if modeChunk then
    while true do
        io.write(out)
        coroutine.yield()
    end
else
    local buffer = ""
    while true do
        buffer = buffer .. out
        if #buffer >= 16 then
            coroutine.yield()
            io.write(buffer)
            buffer = ""
        end
    end
end
