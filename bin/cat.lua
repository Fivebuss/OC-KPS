-- /bin/cat.lua
-- Here goes nothing!
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
        if count % 16 == 0 then
            local sig = coroutine.yield()
            if sig then break end
        end

        chunk = reader:read(chunkSize)
    end
end

if #args == 0 then
    -- Interactive mode
    while true do
        local line, _, noNewline = io.read("l")
        if not line then break end

        -- Lmao how is a signal coming as a line?
        if process.isSignal(line) then break end

        io.write(noNewline and line or (line .. "\n"))
        io.flush()
        coroutine.yield()
    end
    return
end

if #args > 1 then
    io.writelnError("cat: too many arguments")
    return
end

local firstArg = args[1]
local target = console.stripQuotes(firstArg)
local fullPath = console.resolvePath(console.currPath(), target)

if not filesystem.exists(fullPath) or filesystem.isDirectory(fullPath) then
    io.writelnError("cat: " .. firstArg .. ": No such file")
    return
end

local handle, reason = filesystem.open(fullPath, "rb")
if not handle then
    handle, reason = filesystem.open(fullPath, "r")
end
if not handle then
    io.writelnError("cat: " .. firstArg .. ": Cannot open file: " .. tostring(reason))
    return
end

chunkRead(handle)
handle:close()