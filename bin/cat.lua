-- /bin/cat.lua
local filesystem = require("filesystem")
local process = polaris.process

local chunkSize = 2048

-- I hope pipes work again
local function chunkRead(reader)
    local count = 0
    local chunk = reader:read(chunkSize)

    while chunk do
        local ok = io.write(chunk)
        if not ok then break end

        io.flush()

        count = count + 1
        if count % 4 == 0 then
            local sig = coroutine.yield()
            if sig and process.isSignal(sig) then break end
        end

        chunk = reader:read(chunkSize)
    end
end

-- interactive
local function readStdin()
    while true do
        local line, _, noNewline = io.read("l")
        if not line then break end

        -- Lmao how is a signal coming as a line?
        if process.isSignal(line) then break end

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

    local handle, reason = filesystem.open(fullPath, "rb")
    if not handle then
        handle, reason = filesystem.open(fullPath, "r")
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
if #args == 0 then
    readStdin()
else
    local hasError = false
    for _, arg in ipairs(args) do
        if not processTarget(arg) then
            hasError = true
        end
    end

    if hasError then
        os.exit(1)
    end
end