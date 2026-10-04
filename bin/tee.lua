-- /bin/tee.lua
local filesystem = require("filesystem")
local process = polaris.process

local append = false
local ignoreInt = false
local files = {}

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
    local h, reason = filesystem.open(full, mode)
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

local chunkSize = 2048
while true do
    local chunk = io.stdin:read(chunkSize)
    if not chunk then break end
    if process.isSignal(chunk) then
        if not ignoreInt then break end
    else
        writeAll(chunk)
    end
    coroutine.yield()
end

for _, h in ipairs(handles) do
    h:close()
end
