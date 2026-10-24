-- /usr/bin/ping.lua
-- Okay lets do this one more time
-- ping [-c count] [-W timeout] [-s size] <destination>

local network  = require("network")
local process  = require("process")
local computer = require("computer")
local getopt   = require("ksh.getopt")

local TIME     = 1

local args     = { ... }

local function usage()
    io.writeln("usage: ping [-c count] [-W timeout] [-s size] <destination>")
end

local count, timeout, size = 4, 5, 56
local values = {}

for opt, val in getopt(args, "c:W:s:h", { help = "h" }) do
    if opt == "h" or opt == "?" and (val == "h" or val == "?") then
        usage()
        os.exit(0)
        return false
    elseif opt == "?" then
        io.writelnError("ping: unknown option: " .. tostring(val))
        os.exit(1)
        return false
    elseif opt == ":" then
        io.writelnError("ping: option requires an argument: -" .. tostring(val))
        os.exit(1)
        return false
    elseif opt == "c" or opt == "W" or opt == "s" then
        local parsed = tonumber(val)
        if parsed == nil then
            io.writelnError("ping: invalid value for -" .. opt .. ": " .. tostring(val))
            os.exit(1)
            return false
        end
        values[opt] = parsed
    end
end

for _, v in ipairs(args) do
    if values.target ~= nil then
        io.writelnError("ping: more than one destination given")
        os.exit(1)
        return false
    end
    values.target = v
end

if values.c ~= nil then
    if values.c < 1 or values.c % 1 ~= 0 or values.c > 1000 then
        io.writelnError("ping: count must be an integer 1..1000")
        os.exit(1)
        return false
    end
    count = math.floor(values.c)
end
if values.W ~= nil then
    if values.W <= 0 or values.W > 120 then
        io.writelnError("ping: timeout must be 0 < s <= 120")
        os.exit(1)
        return false
    end
    timeout = values.W
end
if values.s ~= nil then
    if values.s < 0 or values.s > 65535 then
        io.writelnError("ping: size must be 0..65535")
        os.exit(1)
        return false
    end
    size = math.floor(values.s)
end

local dst = values.target
if dst == nil then
    usage()
    io.writelnError("ping: destination required")
    os.exit(1)
    return false
end

local icmpId = network.newId() % 65536
local payload = string.rep("a", size)

io.writeln("PING " .. dst .. ": " .. tostring(size) .. " data bytes")

local sent, received, interrupted = 0, 0, false
local rttMin, rttMax, rttSum = math.huge, 0, 0

-- Weirdly laggy?
for seq = 0, count - 1 do
    local started = computer.uptime()
    local result, err = network.admin.ping(dst, icmpId, seq, payload, timeout)

    if err then
        if process.isSignal(err) or err == "HUP"
        then
            interrupted = true
            break
        elseif err == "timeout" then
            sent = sent + 1
            io.writeln(string.format(
                "Request timeout for icmp_seq=%d (%s s)",
                seq, tostring(timeout)
            ))
        else
            io.writelnError("ping: " .. tostring(err))
            os.exit(1)
            return false
        end
    else
        local rtt = computer.uptime() - started
        if result.type == "reply" then
            sent = sent + 1
            received = received + 1
            io.writeln(string.format(
                "%d bytes from %s: icmp_seq=%d time=%.1f ms",
                size + 8, dst, result.seq or seq, rtt * 1000
            ))
            rttSum = rttSum + rtt
            if rtt < rttMin then rttMin = rtt end
            if rtt > rttMax then rttMax = rtt end
        else
            sent = sent + 1
            io.writeln(string.format(
                "Request timeout for icmp_seq=%d (%s s)",
                result.seq or seq, tostring(timeout)
            ))
        end
    end

    if seq < count - 1 then
        os.sleep(TIME)
    end
end

io.writeln("--- " .. dst .. " ping statistics ---")
io.writeln(string.format(
    "%d packets sent, %d received, %.0f%% loss",
    sent, received,
    (sent > 0) and ((sent - received) * 100 / sent) or 0
))
if received > 0 then
    io.writeln(string.format(
        "round-trip min/avg/max = %.1f/%.1f/%.1f ms",
        rttMin * 1000, rttSum * 1000 / received, rttMax * 1000
    ))
end

if interrupted then
    os.exit(2)
    return false
elseif received < count then
    os.exit(1)
    return false
end

os.exit(0)
return false