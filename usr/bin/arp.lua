-- /usr/bin/arp.lua
-- Show or flush the arp cache

local network = require("network")

local args = { ... }

if args[1] == "flush" or args[1] == "-f" then
    local ok, err = network.admin.arpFlush()
    if not ok then
        io.writelnError("arp: " .. tostring(err))
        os.exit(1)
        return false
    end
    os.exit(0)
    return false
end

if args[1] ~= nil then
    io.writelnError("usage: arp [-f | flush]")
    os.exit(1)
    return false
end

local entries, err = network.admin.arp()
if not entries then
    io.writelnError("arp: " .. tostring(err))
    os.exit(1)
    return false
end

io.writeln("IP                hwaddr                                iface     ttl")
for _, entry in ipairs(entries) do
    io.writeln(string.format(
        "%-17s %-37s %-9s %ss",
        entry.ip,
        (entry.ha ~= nil and entry.ha ~= "") and entry.ha or "?",
        entry.iface,
        tostring(entry.remaining or 0)
    ))
end

os.exit(0)
return false
