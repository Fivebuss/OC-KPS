-- /bin/users.lua
-- This is not a great solution

local args = {...}
local process = require("process")
local users = require("users")

local numeric = false

for _, arg in ipairs(args) do
    if arg == "-i" then
        numeric = true
    else
        io.writelnError("Usage: users [-i]")
        os.exit(1)
    end
end

local procs = process.list()
local seen = {}

for _, proc in ipairs(procs) do
    local uid = proc.uid

    if uid ~= nil then
        local user

        if numeric then
            user = tostring(uid)
        else
            user = users.name(uid) or tostring(uid)
        end

        seen[user] = true
    end
end

local list = {}

for user in pairs(seen) do
    list[#list + 1] = user
end

table.sort(list)

io.writeln(table.concat(list, " "))