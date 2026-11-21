-- /bin/tee.lua
local filesystem = require("filesystem")

local append = false
local ignoreInt = false
local files = {}
local stopLoop = false

process.self().setHandle(process.SIG.INT, function()
    if not ignoreInt then
        stopLoop = true
    end
end)

for _, a in ipairs(args) do
    if a == "--help" then
        io.writeln("Usage: tee [-a] [-i] [--] [FILE...]")
        io.writeln("Copies stdin to stdout and FILE(s)")
        io.writeln("If no FILE(s) are given, reads and writes to stdout")
        io.writeln("  -a, appends instead of overwriting FILE(s)")
        io.writeln("  -i, ignores SIGINT")
        io.writeln("tee -- ; skips option parsing so files can begin with -")
        os.exit(0)
    end
end

local i = 1
while i <= #args do
    local a = args[i]
    if a == "-a" then
        append = true
    elseif a == "-i" then
        ignoreInt = true
    elseif a == "--" then
        i = i + 1
        break
    elseif a:sub(1, 1) == "-" then
        io.writelnError("tee: invalid option: " .. a)
        os.exit(1)
    else
        files[#files + 1] = a
    end
    i = i + 1
end
while i <= #args do
    files[#files + 1] = args[i]
    i = i + 1
end

-- Open output files
local handles = {}
local mode = append and "a" or "w"
for _, name in ipairs(files) do
    local full = console.resolvePath(console.currPath(), name)
    local h, reason = io.open(full, mode)
    if not h then
        io.writelnError("tee: " .. name .. ": " .. tostring(reason))
        -- Keep going though
    else
        handles[#handles + 1] = h
    end
end

local function writeAll(chunk)
    io.write(chunk)
    io.flush()

    for _, h in ipairs(handles) do
        h:write(chunk)
    end
end

local function chunkRead()
    while not stopLoop do
        local chunk = io.stdin:read(2048)
        if not chunk then break end

        writeAll(chunk)

        coroutine.yield()
    end
end

local function lineRead()
    while not stopLoop do
        local line, _, noNewline = io.read("l")
        if not line then break end

        writeAll(noNewline and line or (line .. "\n"))

        coroutine.yield()
    end
end

local stdinInfo = require("io").describeStream(io.stdin)

if stdinInfo.kind == "pipe" then
    chunkRead()
else
    lineRead()
end

for _, h in ipairs(handles) do
    h:close()
end

if stopLoop then
    os.exit(130)
end
