---@diagnostic disable: cast-local-type
-- /bin/ping.lua

local event = require("event")
local computer = require("computer")
local net = require("knet")

local args = { ... }

local function usage()
    io.write("Usage: ping [-c count] [-t timeout] <host>\n")
    io.write("Options:\n")
    io.write("  -c count    Stop after sending count packets (default: 5)\n")
    io.write("  -t timeout  Timeout in seconds to wait for each reply (default: 10)\n")
end

-- Parse arguments
local count = 5
local timeout = 10
local host

local i = 1
while i <= #args do
    local arg = args[i]
    if arg == "-c" then
        i = i + 1
        count = tonumber(args[i])
        if not count or count <= 0 then
            io.write("ping: bad number of packets to transmit: '", args[i] or "", "'\n")
            return
        end
    elseif arg == "-t" then
        i = i + 1
        timeout = tonumber(args[i])
        if not timeout or timeout <= 0 then
            io.write("ping: bad timeout: '", args[i] or "", "'\n")
            return
        end
    elseif arg:sub(1, 1) == "-" then
        io.write("ping: invalid option -- '", arg:sub(2), "'\n")
        usage()
        return
    else
        if host then
            io.write("ping: only one host allowed\n")
            return
        end
        host = arg
    end
    i = i + 1
end

if not host then
    io.write("ping: missing host operand\n")
    usage()
    return
end

-- Use minitel default port
local port = 4000

local sent = 0
local received = 0
local min_rtt = math.huge
local max_rtt = 0
local total_rtt = 0
local start_time = computer.uptime()

io.write("PING ", host, " (", computer.address(), "): 56 data bytes\n")
-- yeah lets discard the kb event
event.pull(0.05)
while sent < count do
    sent = sent + 1
    local ping_start = computer.uptime()
    local packet_id = net.rsend(host, port, "ping", true)

    if not packet_id then
        io.write("ping: send failed\n")
        break
    end

    -- Wait for ack
    local event_name, ack_id = event.pull(timeout, "net_ack")

    local ping_end = computer.uptime()
    local rtt = ping_end - ping_start

    if event_name and ack_id == packet_id then
        received = received + 1
        total_rtt = total_rtt + rtt
        min_rtt = math.min(min_rtt, rtt)
        max_rtt = math.max(max_rtt, rtt)
        io.write(string.format("%d bytes from %s: icmp_seq=%d time=%.3f ms\n",
            56, host, sent - 1, rtt * 1000))
    else
        io.write(string.format("Request timeout for icmp_seq %d\n", sent - 1))
    end
end

local end_time = computer.uptime()
local total_time = end_time - start_time

io.write("\n--- ", host, " ping statistics ---\n")
io.write(string.format("%d packets transmitted, %d received, %d%% packet loss, time %.0fms\n",
    sent, received, sent > 0 and math.floor((1 - received / sent) * 100) or 0, total_time * 1000))

if received > 0 then
    io.write(string.format("round-trip min/avg/max = %.3f/%.3f/%.3f ms\n",
        min_rtt * 1000, (total_rtt / received) * 1000, max_rtt * 1000))
end
