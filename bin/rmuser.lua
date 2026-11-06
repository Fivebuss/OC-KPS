-- /bin/rmuser.lua

local args = { ... }
local users = require("users")

if #args > 2 or #args == 0 then
    io.writelnError("Usage: rmuser [-d delete-home] <username>")
    os.exit(1)
end

local username
local delete = false

if args[1] == "-d" then
    username = args[2]
    delete = true
else
    username = args[1]
end

local uid, err = users.lookup(username)

if uid == nil then
    io.writelnError("rmuser: User '" .. username .. "' does not exist")
    os.exit(1)
end

local status, err = users.remove(username)

if status == nil then
    io.writelnError("rmuser: Failed to remove user '" ..
        username .. "': " .. tostring(err))
    os.exit(1)
end

io.writeln("Removed user '" .. username .. "' with UID " .. uid)

if delete then
    local path = "/home/" .. username
    require("filesystem").remove(path)
    io.writeln("Removed '" .. path .. "'")
end
