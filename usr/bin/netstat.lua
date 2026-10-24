-- /usr/bin/netstat.lua
-- Who owns what?

local network = require("network")

local sockets, err = network.admin.sockets()
if not sockets then
    io.writelnError("netstat: " .. tostring(err))
    os.exit(1)
    return false
end

io.writeln(string.format(
    "%-6s %-6s %-21s %-21s %-6s %s",
    "Proto", "Id", "Local", "Remote", "Owner", "Qu"
))

for _, sock in ipairs(sockets) do
    io.writeln(string.format(
        "UDP    %-6d %-21s %-21s %-6s %d",
        sock.id,
        (sock.laddr or "?") .. ":" .. tostring(sock.lport or 0),
        (sock.raddr or "?") .. ":" .. tostring(sock.rport or 0),
        tostring(sock.owner or "-"),
        sock.queue or 0
    ))
end

if #sockets == 0 then
    io.writeln("(no UDP sockets)")
end

-- TCP
local tcpSockets = network.admin.tcpSockets()
if tcpSockets then
    io.writeln(string.format(
        "%-6s %-6s %-21s %-21s %-12s %-6s %s",
        "Proto", "Id", "Local", "Remote", "State", "Owner", "Qu"
    ))

    for _, sock in ipairs(tcpSockets) do
        io.writeln(string.format(
            "TCP    %-6d %-21s %-21s %-12s %-6s %d",
            sock.id,
            (sock.laddr or "?") .. ":" .. tostring(sock.lport or 0),
            (sock.raddr or "?") .. ":" .. tostring(sock.rport or 0),
            tostring(sock.state or "-"),
            tostring(sock.owner or "-"),
            sock.queue or 0
        ))
    end

    if #tcpSockets == 0 then
        io.writeln("(no TCP sockets)")
    end
end

os.exit(0)
return false
