-- /bin/yes.lua
-- yes man
local args = { ... }

local modeChunk = false
local modeNoNewline = false
local str = "y"

local stopLoop = false

process.self().setHandle(process.SIG.INT, function()
    stopLoop = true
end)

-- -c coroutine yields for one character, as batching writes is a lazy trick for performance
-- But you may not want it

for _, a in ipairs(args) do
    if a == "--help" then
        io.writeln("Usage: yes [-c] [-n] [STRING]")
        io.writeln("Repeatedly until stopped outputs 'y' or STRING to stdout")
        io.writeln("  -n, doesnt add a newline to the output")
        io.writeln("  -c, does not batch output")
        os.exit(0)
    end
end

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
    while not stopLoop do
        io.write(out)
        coroutine.yield()
    end
else
    local buffer = ""
    while not stopLoop do
        buffer = buffer .. out
        if #buffer >= 16 then
            coroutine.yield()
            io.write(buffer)
            buffer = ""
        end
    end
end

if stopLoop then
    os.exit(130)
end
