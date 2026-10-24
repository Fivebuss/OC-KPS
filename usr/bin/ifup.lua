-- /usr/bin/ifup.lua
-- Bring a network interface up

local network = require("network")

local args = { ... }

if #args ~= 1 then
    io.writelnError("usage: ifup <interface>")
    os.exit(1)
    return false
end

local ok, err = network.admin.ifup(args[1])
if not ok then
    io.writelnError("ifup: " .. tostring(args[1]) .. ": " .. tostring(err))
    os.exit(1)
    return false
end

io.writeln(args[1] .. ": up")

os.exit(0)
return false
