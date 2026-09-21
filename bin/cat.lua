-- /bin/cat.lua
-- Here goes nothing!
local filesystem = require("filesystem")
local process = polaris.process

local chunkSize = 2048

local function chunkRead(reader)
    local count = 0
    local chunk = reader:read(chunkSize)

    while chunk do
        local ok = io.write(chunk)
        if not ok then break end

        io.flush()

        count = count + 1
        if count % 16 == 0 then
            process.checkCancel()
        end

        chunk = reader:read(chunkSize)
    end
end

if #args <= 1 then
    -- Interactive mode
    while true do
        local line = io.read("l")
        if not line then break end
        io.write(line, "\n")
        io.flush()
        process.checkCancel()
    end
    return
end

if #args > 2 then
    io.writelnError("cat: too many arguments")
    return
end

local rawArg = args[2]
local target = console.stripQuotes(rawArg)
local fullPath = console.resolvePath(console.currPath(), target)

if not filesystem.exists(fullPath) or filesystem.isDirectory(fullPath) then
    io.writelnError("cat: " .. rawArg .. ": No such file")
    return
end

local handle, reason = filesystem.open(fullPath, "rb")
if not handle then
    handle, reason = filesystem.open(fullPath, "r")
end
if not handle then
    io.writelnError("cat: " .. rawArg .. ": Cannot open file: " .. tostring(reason))
    return
end

chunkRead(handle)
handle:close()