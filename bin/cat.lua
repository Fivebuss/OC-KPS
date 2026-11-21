-- /bin/cat.lua
local filesystem = require("filesystem")

local chunkSize = 2048
local stopLoop = false

-- mmm handlers
process.self().setHandle(process.SIG.INT, function()
    stopLoop = true
end)

-- I hope pipes work again
local function chunkRead(reader)
    local count = 0

    while not stopLoop do
        local chunk = reader:read(chunkSize)
        if not chunk then break end

        local ok = io.write(chunk)
        if not ok then break end

        count = count + #chunk

        if count >= 2048 then
            count = 0
            coroutine.yield()
        end
    end
end

-- interactive
local function readStdin()
    while true do
        local line, _, noNewline = io.read("l")
        if not line or stopLoop then break end

        io.write(noNewline and line or (line .. "\n"))
        io.flush()

        coroutine.yield()
    end
end

local function processTarget(rawArg)
    -- '-' is stdin
    if rawArg == "-" then
        readStdin()
        return true
    end

    local target = console and console.stripQuotes(rawArg) or rawArg
    local fullPath = console and console.resolvePath(console.currPath(), target) or target

    if not filesystem.exists(fullPath) then
        io.writelnError("cat: " .. rawArg .. ": No such file or directory")
        return false
    end

    if filesystem.isDirectory(fullPath) then
        io.writelnError("cat: " .. rawArg .. ": Is a directory")
        return false
    end

    local handle, reason = io.open(fullPath, "rb")
    if not handle then
        handle, reason = io.open(fullPath, "r")
    end

    if not handle then
        io.writelnError("cat: " .. rawArg .. ": Cannot open file: " .. tostring(reason))
        return false
    end

    chunkRead(handle)
    handle:close()
    return true
end

-- Begin
local fileArgs = {}
local helpRequested = false
local stopOptions = false

-- Supports -- because files can have - in them which I forgot here
for _, a in ipairs(args) do
    if not stopOptions and a == "--" then
        stopOptions = true
    elseif not stopOptions and a == "--help" then
        helpRequested = true
    else
        table.insert(fileArgs, a)
    end
end

if helpRequested then
    io.writeln("Usage: cat [FILE]...")
    io.writeln("Concatenates files to stdout")
    io.writeln("\nWith no FILE(s), or when FILE is -, reads from stdin")
    os.exit(0)
end

if #fileArgs == 0 then
    readStdin()
else
    local hasError = false
    for _, arg in ipairs(fileArgs) do
        if not processTarget(arg) then
            hasError = true
        end
    end

    if hasError then
        os.exit(1)
    end
end
