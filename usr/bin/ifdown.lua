-- /usr/bin/ifdown.lua
-- Bring a network interface down

local network = require("network")

local args = { ... }

if #args ~= 1 then
    io.writelnError("usage: ifdown <interface>")
    os.exit(1)
    return false
end

local ok, err = network.admin.ifdown(args[1])
if not ok then
    io.writelnError("ifdown: " .. tostring(args[1]) .. ": " .. tostring(err))
    os.exit(1)
    return false
end

io.writeln(args[1] .. ": down")

os.exit(0)
return false
