-- /bin/whoami.lua
-- Oh look, multi-user exists finally
local args = {...}
local uid = process.self().uid
local user

for _, a in ipairs(args) do
    if a == "--help" then
        io.writeln("Usage: whoami [-i]")
        io.writeln("Shows who you are, of course")
        io.writeln("  -i, displays UID")
        os.exit(0)
    end
end

if args[1] == "-i" then
    user = uid
else
    user = getenv("USER") or nil
end
if user == nil then
    user = process.self().uid or nil
end
if user == nil then
    io.writelnError("whoami: Unable to determine user")
    os.exit(1)
else
    io.writeln(user)
end
