-- /bin/adduser.lua
-- For fun tbh

local args = {...}
local users = require("users")

if #args ~= 1 then
    io.writelnError("Usage: adduser <username>")
    os.exit(1)
end

local username = args[1]

if users.exists(username) then
    io.writelnError("adduser: User '" .. username .. "' already exists")
    os.exit(1)
end

local uid, err = users.add(username)

if uid == nil then
    io.writelnError("adduser: Failed to add user '" ..
        username .. "': " .. tostring(err))
    os.exit(1)
end

io.writeln("Added user '" .. username .. "' with UID " .. uid)