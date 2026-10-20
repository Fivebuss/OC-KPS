-- /bin/whoami.lua
-- Oh look, multi-user exists finally
local args = {...}
local uid = require("process").self().uid
local user

if args[1] == "-i" then
    user = uid
else
    user = getenv("USER") or nil
end
if user == nil then
    user = require("process").self().uid or nil
end
if user == nil then
    io.writelnError("whoami: Unable to determine user")
    os.exit(1)
else
    io.writeln(user)
end
