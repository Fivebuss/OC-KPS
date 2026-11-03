-- /bin/env.lua

-- Yes yes builtins are cooked, dont bother me
-- I may need to fix this later.
local filesystem = require("filesystem")

local pathDirs = {}
for entry in string.gmatch("/bin:/sbin", "[^:]+") do
    pathDirs[#pathDirs + 1] = entry
end

local function resolveCommand(name)
    for _, dir in ipairs(pathDirs) do
        local candidate = filesystem.concat(dir, name .. ".lua")
        if filesystem.exists(candidate) and not filesystem.isDirectory(candidate) then
            return candidate
        end
    end
    return nil
end

local i = 1
local clearFirst = false

if args[i] == "-i" then
    clearFirst = true
    i = i + 1
end

if clearFirst then
    for key in pairs(getall()) do
        setenv(key, nil)
    end
end

while args[i] do
    local name, value = args[i]:match("^([%a_][%w_]*)=(.*)$")
    if not name then break end
    setenv(name, value)
    i = i + 1
end

if not args[i] then
    for key, value in pairs(getall()) do
        io.writeln(key .. "=" .. tostring(value))
    end
    return
end

local cmdName = args[i]
local resolved = resolveCommand(cmdName)
if not resolved then
    io.writelnError("env: " .. cmdName .. ": No such file or directory")
    return
end

local src, reason = io.open(resolved, "r")
if not src then
    io.writelnError("env: cannot open " .. cmdName .. ": " .. tostring(reason))
    return
end

local chunks = {}
while true do
    local chunk = src:read(math.huge)
    if not chunk then break end
    chunks[#chunks + 1] = chunk
end
src:close()

local fn, loadErr = load(table.concat(chunks), "=" .. resolved, "bt")
if not fn then
    io.writelnError("env: " .. loadErr)
    return
end

local args = { table.unpack(args, i + 1) }
fn(table.unpack(args))