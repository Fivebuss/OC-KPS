-- /usr/bin/nc.lua
-- UDP and TCP its great
-- so helpful for testing

local network = require("network")
local process = require("process")
local getopt  = require("ksh.getopt")

local args    = { ... }

local function usage()
    io.writeln("usage: nc [-u] <address> <port>")
    io.writeln("       nc [-u] -l [address] [port]   (one connection at a time)")
end

local function die(msg)
    io.writelnError("nc: " .. msg)
    os.exit(1)
    return false
end

local listenMode = false
local udpMode = false
local bindAddr = nil
local bindPort = 0
local bareArgs = {}

for opt, val in getopt(args, "hlus:p:") do
    if opt == "h" then
        usage()
        os.exit(0)
        return false
    elseif opt == "?" then
        return die("invalid option: -" .. tostring(val))
    elseif opt == ":" then
        return die("option -" .. tostring(val) .. " needs a value")
    elseif opt == "l" then
        listenMode = true
    elseif opt == "u" then
        udpMode = true
    elseif opt == "p" then
        local n = tonumber(val)
        if n == nil or n < 0 or n > 65535 or n % 1 ~= 0 then
            return die("invalid local port: " .. tostring(val))
        end
        bindPort = math.floor(n)
    elseif opt == "s" then
        local parsed = network.address.parse(val)
        if parsed == nil then
            return die("invalid local address: " .. tostring(val))
        end
        bindAddr = val
    end
end

for _, v in ipairs(args) do
    bareArgs[#bareArgs + 1] = v
end

-- I gotta make sure it cant double loop still but its fine
local function listenEndpoint()
    local laddr, lport = bindAddr, bindPort
    if #bareArgs == 1 then
        if network.address.parse(bareArgs[1]) ~= nil then
            laddr = bareArgs[1]
        else
            local n = tonumber(bareArgs[1])
            if n == nil then
                return nil, nil, "invalid listen argument: " .. tostring(bareArgs[1])
            end
            lport = math.floor(n)
        end
    elseif #bareArgs >= 2 then
        laddr = bareArgs[1]
        local n = tonumber(bareArgs[2])
        if n == nil then
            return nil, nil, "invalid listen port: " .. tostring(bareArgs[2])
        end
        lport = math.floor(n)
    end
    return laddr, lport
end

local function connectEndpoint()
    if #bareArgs < 2 then
        usage()
        return nil, nil, "an address and a port are required"
    end
    local dstPort = tonumber(bareArgs[2])
    if dstPort == nil or dstPort < 1 or dstPort > 65535 or dstPort % 1 ~= 0 then
        return nil, nil, "invalid destination port: " .. tostring(bareArgs[2])
    end
    return bareArgs[1], math.floor(dstPort)
end

local sock

if udpMode then
    sock = network.udp.new()

    if listenMode then
        local laddr, lport, err = listenEndpoint()
        if err then
            return die(err)
        end

        local addr, port = network.udp.bind(sock, laddr, lport)
        if addr == nil then
            return die("bind: " .. tostring(port))
        end
        io.writeln("Listening on " .. addr .. ":" .. tostring(port))
    else
        local dst, dstPort, err = connectEndpoint()
        if err then
            return die(err)
        end

        local addr, port = network.udp.bind(sock, bindAddr, bindPort)
        if addr == nil then
            return die("bind: " .. tostring(port))
        end
        local raddr, rport = network.udp.connect(sock, dst, dstPort)
        if raddr == nil then
            return die("connect: " .. tostring(rport))
        end
        io.writeln("Connected to " .. raddr .. ":" .. tostring(rport))
    end
else
    sock = network.tcp.new()

    -- Im aware a TCP internal bug doesnt break listener. Go away
    if listenMode then
        local laddr, lport, err = listenEndpoint()
        if err then
            return die(err)
        end

        local addr, port = network.tcp.listen(sock, laddr, lport)
        if addr == nil then
            return die("listen: " .. tostring(port))
        end
        io.writeln("Listening on " .. addr .. ":" .. tostring(port))

        local conn, accErr = network.tcp.accept(sock)
        if conn == nil then
            network.tcp.close(sock)
            return die("accept: " .. tostring(accErr))
        end
        sock = conn
        io.writeln("Connection from " .. tostring(sock.raddr) .. ":" ..
            tostring(sock.rport))
    else
        local dst, dstPort, err = connectEndpoint()
        if err then
            return die(err)
        end

        local addr, port = network.tcp.bind(sock, bindAddr, 0)
        if addr == nil then
            return die("bind: " .. tostring(port))
        end
        local raddr, rport = network.tcp.connect(sock, dst, dstPort)
        if raddr == nil then
            return die("connect: " .. tostring(rport))
        end
        io.writeln("Connected to " .. raddr .. ":" .. tostring(rport))
    end
end

local mainPid = process.self().pid
local childPid = nil

local function readerMain()
    while true do
        local line = process.input():readLine(true)
        if line == nil then
            process.send(mainPid, { nc = "eof" })
            return
        end
        process.send(mainPid, { nc = "line", line = line })
    end
end

childPid = process.spawn(readerMain, { label = "nc reader" })
process.create(childPid,
    (process.input()):retain(),
    process.output(),
    process.error())

local open        = true
local hadError    = false
local pendingRecv = nil
local lastFrom, lastPort

local recvOp      = udpMode and "udp_recv" or "tcp_recv"
local cancelOp    = udpMode and "udp_recv_cancel" or "tcp_recv_cancel"

local function prepRecv()
    if not open or pendingRecv ~= nil or sock.id == nil then
        return
    end
    local daemon = network.ipc.getDaemon()
    if daemon == nil then
        io.writelnError("nc: knetd not running")
        hadError = true
        open = false
        return
    end
    local req = network.ipc.request(recvOp, { socketId = sock.id })
    if not network.ipc.send(daemon, req) then
        io.writelnError("nc: knetd not running")
        hadError = true
        open = false
        return
    end
    pendingRecv = req
end

local function dropRecv()
    if pendingRecv == nil then
        return
    end
    local daemon = network.ipc.getDaemon()
    if daemon then
        network.ipc.send(daemon, network.ipc.request(cancelOp,
            { socketId = sock.id, reqId = pendingRecv.id }))
    end
    pendingRecv = nil
end

local function outputDatagram(data, fromDotted, port)
    io.write(data or "")
    io.flush()
end

prepRecv()
-- Cursed
while open do
    local value = process.waitForInput()

    if value == nil then
        break
    end

    if type(value) == "string" and process.isSignal(value) then
        break
    end

    if type(value) == "table" then
        if value.network and value.kind == "reply" and pendingRecv ~= nil and
            value.id == pendingRecv.id
        then
            pendingRecv = nil
            if not value.ok then
                if value.err == "closed" then
                    open = false
                else
                    hadError = true
                    io.writelnError("nc: receive failed: " ..
                        tostring(value.err or "error"))
                    open = false
                end
            else
                local fromDotted =
                    value.from and network.address.dotted(value.from) or nil
                lastFrom, lastPort = fromDotted, value.port
                outputDatagram(value.data, fromDotted, value.port)
                prepRecv()
            end
        elseif value.network and value.kind == "data" and sock.id ~= nil and
            value.ref == sock.id
        then
            pendingRecv = nil
            local fromDotted = value.from and network.address.dotted(value.from) or nil
            lastFrom, lastPort = fromDotted, value.port
            outputDatagram(value.data, fromDotted, value.port)
            prepRecv()
        elseif value.network and value.kind == "notify" and value.op == "tcp" and
            sock.id ~= nil and value.ref == sock.id
        then
            pendingRecv = nil
            if value.type ~= "closed" then
                io.writelnError("nc: " .. tostring(value.type or "error"))
                hadError = true
            end
            open = false
        elseif value.nc == "line" then
            local line = value.line or ""
            local okSend, sendErr
            if listenMode and udpMode then
                if lastFrom ~= nil and lastPort then
                    okSend, sendErr = network.udp.sendto(sock,
                        line .. "\n", lastFrom, lastPort)
                else
                    sendErr = "nothing received yet"
                end
            elseif udpMode then
                okSend, sendErr = network.udp.send(sock, line .. "\n")
            else
                okSend, sendErr = network.tcp.send(sock, line .. "\n")
            end
            if not okSend then
                io.writelnError("nc: send: " .. tostring(sendErr))
                hadError = true
            end
            if not network.ipc.getDaemon() then
                io.writelnError("nc: knetd not running")
                hadError = true
                open = false
            end
        elseif value.nc == "eof" then
            if udpMode then
                break
            end
            dropRecv()
            if sock.id ~= nil then
                local closed, closeErr = network.tcp.close(sock)
                if closed == nil then
                    io.writelnError("nc: close: " .. tostring(closeErr))
                    hadError = true
                end
            end
            break
        end
    end
end

dropRecv()
if sock.id ~= nil then
    if udpMode then
        network.udp.close(sock)
    else
        network.tcp.close(sock)
    end
end
if childPid ~= nil then
    process.kill(childPid)
end
io.flush()

os.exit(hadError and 1 or 0)
return false
