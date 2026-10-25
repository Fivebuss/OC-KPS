-- /usr/lib/network/proto/tcp.lua
-- TCP except not compliant lol. Thanks OSInet!
--
-- Thanks AI for --V
-- Socket records (plain tables, no classes)
--   { id, state, laddr (num), lport, raddr (num), rport, owner (client pid),
--     listener (parent listen socket id, accepted sockets only),
--     mssAdv (what we advertise), mss (send cap, min of peer option/ours),
--     iss, irs, sndUna, sndNxt, rcvNxt, sndWnd (peer's advertised window),
--     sndQueue = { entry }, rcvQueue = { data }, acceptQueue = { childId },
--     eof (peer FIN seen), waiter, acceptWaiter, connectWaiter, closeWaiter,
--     timeWaitDeadline }
--   entry = { seq, flags, payload, len, sent, deadline, tries, mss }

local const = require("network.const")
local wire = require("network.wire")
local address = require("network.address")

local M = {}

M.FLAGS = {
    FIN = 1,
    SYN = 2,
    RST = 4,
    PSH = 8,
    ACK = 16,
    URG = 32,
}

local notifyFn      = nil
local sendIPFn      = nil
local mssResolverFn = nil
local logFn         = nil

function M.setNotify(fn) notifyFn = fn end
function M.setSendIP(fn) sendIPFn = fn end
function M.setMssResolver(fn) mssResolverFn = fn end
function M.setLog(fn) logFn = fn end

local function log(msg)
    if logFn then pcall(logFn, "tcp: " .. tostring(msg)) end
end

local computer = require("computer")

local function now()
    local ok, t = pcall(computer.uptime)
    if ok and type(t) == "number" then return t end
    return 0
end

local function hasFlag(flags, flag)
    return math.floor(flags / flag) % 2 == 1
end

local function seqLt(a, b)
    local d = (b - a) % 4294967296
    return d > 0 and d < 2147483648
end

local function seqLe(a, b)
    return a == b or seqLt(a, b)
end

-- SYN
local function segLen(seg)
    local n = #(seg.payload or "")
    if hasFlag(seg.flags, M.FLAGS.SYN) then n = n + 1 end
    if hasFlag(seg.flags, M.FLAGS.FIN) then n = n + 1 end
    return n
end

-- Header is like --V 
--   sport u16 | dport u16 | seq u32 | ack u32 | dataOffset u8 | flags u8 |
--   window u16 | checksum u16 | urgent u16 | options | payload
--   checksum over pseudo header: src u32 | dst u32 | zero u8 | proto u8 |
--                                length u16 | whole segment
-- Only the MSS option (kind 2) is understood; the rest is skipped.

local HEADER_LEN = 20

local function packHeader(sport, dport, seq, ack, dataOffset, flags, window,
    checksum, opts)
    return table.concat({
        wire.packU16(sport),
        wire.packU16(dport),
        wire.packU32(seq % 4294967296),
        wire.packU32(ack % 4294967296),
        wire.packU8(dataOffset * 16),
        wire.packU8(flags % 256),
        wire.packU16(window),
        wire.packU16(checksum),
        wire.packU16(0), -- Urgent? Nah,
        opts,
    })
end

-- Makes a segment because this has to be complicated
function M.encodeSegment(seg, src, dst)
    local opts = ""
    local dataOffset = 5
    if hasFlag(seg.flags, M.FLAGS.SYN) and seg.mss then
        opts = table.concat({
            wire.packU8(2),
            wire.packU8(4),
            wire.packU16(seg.mss),
        })
        dataOffset = 6
    end
    local window = seg.window or const.TCP_WINDOW
    local zeroed = packHeader(seg.sport, seg.dport, seg.seq, seg.ack or 0,
        dataOffset, seg.flags, window, 0, opts) .. (seg.payload or "")
    local pseudo = table.concat({
        wire.packU32(src % 4294967296),
        wire.packU32(dst % 4294967296),
        wire.packU8(0),
        wire.packU8(const.PROTOCOLS.TCP),
        wire.packU16(#zeroed),
        zeroed,
    })
    local checksum = wire.checksum(pseudo)
    return packHeader(seg.sport, seg.dport, seg.seq, seg.ack or 0,
        dataOffset, seg.flags, window, checksum, opts) .. (seg.payload or "")
end

-- Decodes to a table
function M.decodeSegment(data, src, dst)
    if type(data) ~= "string" or #data < HEADER_LEN then
        return nil, "segment too short"
    end
    local sport = wire.readU16(data, 1)
    local dport = wire.readU16(data, 3)
    local seq = wire.readU32(data, 5)
    local ack = wire.readU32(data, 9)
    local dataOffset = math.floor(data:byte(13) / 16)
    local flags = data:byte(14)
    local window = wire.readU16(data, 15)
    local checksum = wire.readU16(data, 17)

    if not (sport and dport and seq and ack and flags and window and checksum) then
        return nil, "truncated header"
    end
    if dataOffset < 5 or dataOffset * 4 > #data then
        return nil, "bad data offset"
    end

    if checksum ~= 0 then
        local pseudo = table.concat({
            wire.packU32(src % 4294967296),
            wire.packU32(dst % 4294967296),
            wire.packU8(0),
            wire.packU8(const.PROTOCOLS.TCP),
            wire.packU16(#data),
            data,
        })
        if wire.checksum(pseudo) ~= 0 then
            return nil, "checksum mismatch"
        end
    end

    -- Hopefully bad options dont crash entire thing anymore
    local mss = nil
    local pos = HEADER_LEN + 1
    local optEnd = dataOffset * 4
    while pos <= optEnd do
        local kind = data:byte(pos)
        if kind == 0 then
            break -- done
        elseif kind == 1 then
            pos = pos + 1
        else
            local len = data:byte(pos + 1)
            if len == nil or len < 2 or pos + len - 1 > optEnd then
                return nil, "bad option"
            end
            if kind == 2 and len == 4 then
                mss = wire.readU16(data, pos + 2)
            end
            pos = pos + len
        end
    end

    return {
        sport = sport,
        dport = dport,
        seq = seq,
        ack = ack,
        flags = flags,
        window = window,
        mss = mss,
        payload = #data > optEnd and data:sub(optEnd + 1) or "",
    }
end

-- Socket time
local socketCounter = 0
local sockets = {}

function M.nextSocketId()
    socketCounter = socketCounter + 1
    return socketCounter
end

function M.get(id)
    return sockets[id]
end

function M.list()
    local out = {}
    for _, sock in pairs(sockets) do
        out[#out + 1] = sock
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function M.remove(id)
    local sock = sockets[id]
    if sock then
        sockets[id] = nil
    end
    return sock
end

-- Wildcard. Tf is a tuple? osinet is so lovely
local function tuplesConflict(a, b)
    local function eq(v1, v2)
        return v1 == v2 or v1 == 0 or v2 == 0
    end
    return eq(a.laddr, b.laddr) and eq(a.lport, b.lport) and
        eq(a.raddr, b.raddr) and eq(a.rport, b.rport)
end

-- Hey dont do that
local function reservedEndpoint(laddr, lport)
    return laddr == 2130706433 and lport == const.CONTROL_PORT -- 127.0.0.1
end

-- go find a free port
local function pickEphemeralPort(candidate)
    for _ = 1, 4 do
        local port = math.random(const.EPHEMERAL_PORT_MIN, const.EPHEMERAL_PORT_MAX)
        local partial = {
            laddr = candidate.laddr,
            lport = port,
            raddr = candidate.raddr,
            rport = candidate.rport,
        }
        local conflict = false
        for _, sock in pairs(sockets) do
            if tuplesConflict(partial, sock) then
                conflict = true
                break
            end
        end
        if not conflict then
            return port
        end
    end
    return nil
end

-- Makes a new socket thing
local function allocate(laddr, lport, opts)
    laddr = laddr or 0
    if type(laddr) ~= "number" or laddr < 0 or laddr % 1 ~= 0 or laddr > 4294967295 then
        return nil, "invalid address"
    end
    if type(lport) ~= "number" or lport < 0 or lport % 1 ~= 0 or lport > 65535 then
        return nil, "invalid port"
    end
    if reservedEndpoint(laddr, lport) then
        return nil, "reserved endpoint"
    end

    local candidate = { laddr = laddr, lport = lport, raddr = 0, rport = 0 }
    -- wildcard gets first pick guys
    if candidate.lport ~= 0 then
        for _, sock in pairs(sockets) do
            if tuplesConflict(candidate, sock) then
                return nil, "address already in use"
            end
        end
    else
        local port = pickEphemeralPort(candidate)
        if port == nil then
            return nil, "no free ephemeral port"
        end
        candidate.lport = port
    end

    local id = M.nextSocketId()
    -- good lord
    local sock = {
        id = id,
        state = opts.listen and "LISTEN" or "CLOSED",
        laddr = candidate.laddr,
        lport = candidate.lport,
        raddr = 0,
        rport = 0,
        owner = opts.owner,
        mssAdv = nil,
        mss = nil,
        iss = nil,
        irs = nil,
        sndUna = 0,
        sndNxt = 0,
        rcvNxt = 0,
        sndWnd = const.TCP_WINDOW,
        sndFin = false,
        sndQueue = {},
        rcvQueue = {},
        acceptQueue = opts.listen and {} or nil,
        eof = false,
        waiter = nil,
        acceptWaiter = nil,
        connectWaiter = nil,
        closeWaiter = nil,
        timeWaitDeadline = nil,
    }
    sockets[id] = sock
    return sock
end

-- connect's problem not this
function M.bind(laddr, lport, opts)
    opts = opts or {}
    return allocate(laddr, lport, opts)
end

-- Bind but SYN
function M.listen(laddr, lport, opts)
    opts = opts or {}
    opts.listen = true
    return allocate(laddr, lport, opts)
end

-- Socket matching
local function findListener(dst, dstPort)
    local wildcard = nil
    for _, sock in pairs(sockets) do
        if sock.state == "LISTEN" and sock.lport == dstPort then
            if sock.laddr == dst then
                return sock
            elseif sock.laddr == 0 then
                wildcard = sock
            end
        end
    end
    return wildcard
end

local function findSocket(dst, src, dstPort, srcPort)
    for _, sock in pairs(sockets) do
        if sock.lport == dstPort and sock.laddr == dst and
            sock.rport == srcPort and sock.raddr == src
        then
            return sock
        end
    end
    return nil
end

local function replyWaiter(waiter, ok, payload)
    if type(waiter) ~= "table" or notifyFn == nil then return end
    local msg = {
        network = true,
        kind = "reply",
        id = waiter.reqId,
        pid = waiter.pid,
        ok = ok,
    }
    if ok and type(payload) == "table" then
        for key, value in pairs(payload) do
            msg[key] = value
        end
    elseif not ok then
        msg.err = payload
    end
    pcall(notifyFn, waiter.pid, msg)
end

-- Wake up a pending recv
local function notifyWaiter(sock, waiter, notifyType)
    if type(waiter) ~= "table" or notifyFn == nil then return end
    pcall(notifyFn, waiter.pid, {
        network = true,
        kind = "notify",
        op = "tcp",
        id = waiter.reqId,
        pid = waiter.pid,
        ref = sock.id,
        type = notifyType,
    })
end

local function childInfo(sock)
    return {
        socketId = sock.id,
        addr = address.dotted(sock.laddr),
        port = sock.lport,
        raddr = address.dotted(sock.raddr),
        rport = sock.rport,
    }
end

local abortSocket

-- Done!
local function removeSocket(sock)
    sockets[sock.id] = nil
    if sock.closeWaiter then
        local waiter = sock.closeWaiter
        sock.closeWaiter = nil
        replyWaiter(waiter, true, {})
    end
    if sock.acceptWaiter then
        local waiter = sock.acceptWaiter
        sock.acceptWaiter = nil
        replyWaiter(waiter, false, "listener closed")
    end
    return true
end

-- RST handling
abortSocket = function(sock, reason, silent)
    local connectWaiter = sock.connectWaiter
    local closeWaiter = sock.closeWaiter
    local recvWaiter = sock.waiter
    local hadConnection = sock.state ~= "LISTEN" and sock.state ~= "CLOSED" and
        sock.raddr ~= 0 and sock.rport ~= 0

    sockets[sock.id] = nil
    sock.state = "CLOSED"
    sock.sndQueue = {}
    sock.rcvQueue = {}

    if hadConnection and sendIPFn and not silent then
        -- yeah our partener may just be dead by now
        pcall(sendIPFn, {
            src = sock.laddr,
            dst = sock.raddr,
            proto = const.PROTOCOLS.TCP,
            payload = M.encodeSegment({
                sport = sock.lport,
                dport = sock.rport,
                seq = sock.sndNxt,
                ack = sock.rcvNxt,
                flags = M.FLAGS.RST + M.FLAGS.ACK,
                window = const.TCP_WINDOW,
                payload = "",
            }, sock.laddr, sock.raddr),
        })
    end

    if connectWaiter then replyWaiter(connectWaiter, false, reason) end
    if closeWaiter then replyWaiter(closeWaiter, false, reason) end
    if recvWaiter then
        notifyWaiter(sock, recvWaiter, reason == "timeout" and "timeout" or "reset")
    end
    log("socket " .. tostring(sock.id) .. ": " .. reason)
    return true
end

-- Child socket goes to owner
local function notifyAccepted(child)
    local listener = child.listener and sockets[child.listener] or nil
    if listener == nil or listener.state ~= "LISTEN" or child.accepted then
        return
    end
    if listener.acceptWaiter then
        local waiter = listener.acceptWaiter
        listener.acceptWaiter = nil
        child.accepted = true
        replyWaiter(waiter, true, childInfo(child))
        return
    end
    if #listener.acceptQueue >= const.TCP_QUEUE_MAX then
        table.remove(listener.acceptQueue, 1)
        log("listener " .. tostring(listener.id) .. " accept queue overflow")
    end
    listener.acceptQueue[#listener.acceptQueue + 1] = child.id
end

local function enterTimeWait(sock, nowNum)
    sock.state = "TIME_WAIT"
    sock.timeWaitDeadline = nowNum + const.TCP_TIME_WAIT
    if sock.closeWaiter then
        local waiter = sock.closeWaiter
        sock.closeWaiter = nil
        replyWaiter(waiter, true, {})
    end
end

-- Fancy exponential go away
local function retransmitTimeout(tries)
    return const.TCP_RTO * 2 ^ math.min(tries, 4)
end

-- Give to ip layer
local function transmitEntry(sock, entry)
    if sendIPFn == nil or sock.raddr == 0 or sock.laddr == 0 then
        return nil, "not connected"
    end
    local payload = M.encodeSegment({
        sport = sock.lport,
        dport = sock.rport,
        seq = entry.seq,
        ack = sock.irs and sock.rcvNxt or 0,
        flags = entry.flags,
        window = const.TCP_WINDOW,
        mss = entry.mss,
        payload = entry.payload or "",
    }, sock.laddr, sock.raddr)

    local ok, sent, err = pcall(sendIPFn, {
        src = sock.laddr,
        dst = sock.raddr,
        proto = const.PROTOCOLS.TCP,
        payload = payload,
        encode = function() return payload end,
    })
    if not ok then
        log("send failed: " .. tostring(sent))
        return nil, sent
    end
    if sent == nil then
        return nil, err
    end
    return true
end

-- Add to queue
local function queueEntry(sock, flags, payload, mss)
    local entry = {
        seq = sock.sndNxt,
        flags = flags,
        payload = payload or "",
        len = #(payload or ""),
        sent = false,
        deadline = nil,
        tries = 0,
        mss = mss,
    }
    if hasFlag(flags, M.FLAGS.SYN) then entry.len = entry.len + 1 end
    if hasFlag(flags, M.FLAGS.FIN) then entry.len = entry.len + 1 end
    sock.sndQueue[#sock.sndQueue + 1] = entry
    sock.sndNxt = (sock.sndNxt + entry.len) % 4294967296
    return entry
end

local function sockSend(sock, nowNum)
    while #sock.sndQueue > 0 do
        local head = sock.sndQueue[1]
        if head.sent then
            return
        end
        local inFlight = 0
        for _, entry in ipairs(sock.sndQueue) do
            inFlight = inFlight + entry.len
        end
        if inFlight > sock.sndWnd then
            return
        end
        if not transmitEntry(sock, head) then
            return -- try again
        end
        head.sent = true
        head.deadline = nowNum + retransmitTimeout(0)
    end
end

-- Thanks OSInet
local function advanceUna(sock, ack)
    ack = ack % 4294967296
    if not seqLt(sock.sndUna, ack) or not seqLe(ack, sock.sndNxt) then
        return false -- duplicate, old, or bogus ack
    end
    sock.sndUna = ack
    while #sock.sndQueue > 0 do
        local head = sock.sndQueue[1]
        if seqLe((head.seq + head.len) % 4294967296, ack) then
            table.remove(sock.sndQueue, 1)
        else
            break
        end
    end
    return true
end

-- EOF
local function pumpRecv(sock)
    local waiter = sock.waiter
    if waiter == nil then return end
    if #sock.rcvQueue > 0 then
        local entry = table.remove(sock.rcvQueue, 1)
        sock.waiter = nil
        if notifyFn then
            pcall(notifyFn, waiter.pid, {
                network = true,
                kind = "data",
                pid = waiter.pid,
                ref = sock.id,
                data = entry,
                from = address.dotted(sock.raddr),
                port = sock.rport,
            })
        end
    elseif sock.eof then
        sock.waiter = nil
        notifyWaiter(sock, waiter, "closed")
    end
end

-- You can have these
function M.connect(sock, raddr, rport, src, mssAdv, waiter, nowNum)
    if sock.state ~= "CLOSED" then
        return nil, "socket not idle"
    end
    if type(raddr) ~= "number" or raddr < 0 or raddr % 1 ~= 0 then
        return nil, "invalid address"
    end
    if type(rport) ~= "number" or rport <= 0 or rport % 1 ~= 0 or rport > 65535 then
        return nil, "invalid port"
    end

    local candidate = { laddr = sock.laddr, lport = sock.lport, raddr = raddr, rport = rport }
    for id, other in pairs(sockets) do
        if id ~= sock.id and tuplesConflict(candidate, other) then
            return nil, "address already in use"
        end
    end

    if sock.laddr == 0 then
        sock.laddr = src or 0
    end
    sock.raddr = raddr
    sock.rport = rport
    sock.mssAdv = mssAdv
    sock.mss = mssAdv
    sock.iss = math.random(0, 4294967295)
    sock.sndUna = sock.iss
    sock.sndNxt = (sock.iss + 1) % 4294967296
    sock.rcvNxt = 0
    sock.sndWnd = const.TCP_WINDOW
    sock.state = "SYN_SENT"
    sock.connectWaiter = waiter

    queueEntry(sock, M.FLAGS.SYN, "", mssAdv)
    sockSend(sock, nowNum or now())
    return true
end

-- New connection guys
local function acceptSyn(listener, src, dst, seg)
    local ourMss = mssResolverFn and mssResolverFn(dst, src) or const.TCP_MSS_FALLBACK
    local peerMss = seg.mss or ourMss

    local id = M.nextSocketId()
    local child = {
        id = id,
        state = "SYN_RCVD",
        laddr = dst,
        lport = listener.lport,
        raddr = src,
        rport = seg.sport,
        owner = listener.owner,
        listener = listener.id,
        mssAdv = ourMss,
        mss = math.min(ourMss, peerMss),
        iss = math.random(0, 4294967295),
        irs = seg.seq,
        sndUna = nil,
        sndNxt = nil,
        rcvNxt = (seg.seq + 1) % 4294967296,
        sndWnd = seg.window or const.TCP_WINDOW,
        sndFin = false,
        sndQueue = {},
        rcvQueue = {},
        acceptQueue = nil,
        eof = false,
        waiter = nil,
        acceptWaiter = nil,
        connectWaiter = nil,
        closeWaiter = nil,
        timeWaitDeadline = nil,
    }
    child.sndUna = child.iss
    child.sndNxt = (child.iss + 1) % 4294967296
    sockets[id] = child

    -- SYN+ACK
    queueEntry(child, M.FLAGS.SYN + M.FLAGS.ACK, "", ourMss)
    sockSend(child, now())

    -- Tell it or make child sleep
    if listener.acceptWaiter then
        local waiter = listener.acceptWaiter
        listener.acceptWaiter = nil
        child.accepted = true
        replyWaiter(waiter, true, childInfo(child))
    else
        if #listener.acceptQueue >= const.TCP_QUEUE_MAX then
            table.remove(listener.acceptQueue, 1)
            log("listener " .. tostring(listener.id) .. " accept queue overflow")
        end
        listener.acceptQueue[#listener.acceptQueue + 1] = child.id
        child.accepted = true -- owned by the queue now
    end
    log("socket " .. tostring(id) .. ": synthesized from listener " ..
        tostring(listener.id))
    return true
end

-- Oh look it doesnt hang for 50 years anymore
local function sendRst(localAddr, remoteAddr, localPort, remotePort, seq, ack)
    if sendIPFn == nil then return end
    pcall(sendIPFn, {
        src = localAddr,
        dst = remoteAddr,
        proto = const.PROTOCOLS.TCP,
        payload = M.encodeSegment({
            sport = localPort,
            dport = remotePort,
            seq = seq,
            ack = ack,
            flags = M.FLAGS.RST + M.FLAGS.ACK,
            window = 0,
            payload = "",
        }, localAddr, remoteAddr),
    })
end

local function processSegment(sock, src, dst, seg)
    local flags = seg.flags
    local ackSet = hasFlag(flags, M.FLAGS.ACK)
    local needAck = false
    local finSeen = false
    local nowNum = now()

    -- Cursed
    if sock.state == "TIME_WAIT" then
        if hasFlag(flags, M.FLAGS.FIN) then
            transmitEntry(sock, {
                seq = sock.sndNxt,
                flags = M.FLAGS.ACK,
                payload = "",
                len = 0,
                tries = 0,
            })
        end
        return true
    end

    -- ACK
    if ackSet then
        advanceUna(sock, seg.ack)
        if seg.window and seg.window > 0 then
            sock.sndWnd = seg.window
        end
        sockSend(sock, nowNum)
    end

    if sock.state == "SYN_SENT" then
        if hasFlag(flags, M.FLAGS.SYN) and ackSet then
            sock.irs = seg.seq
            sock.rcvNxt = (seg.seq + 1) % 4294967296
            sock.state = "ESTABLISHED"
            local connectWaiter = sock.connectWaiter
            sock.connectWaiter = nil
            replyWaiter(connectWaiter, true, {
                raddr = address.dotted(sock.raddr),
                rport = sock.rport,
            })
        else
            return false -- not our one
        end
    elseif sock.state == "SYN_RCVD" and ackSet then
        sock.state = "ESTABLISHED"
        notifyAccepted(sock)
    end

    local length = segLen(seg)
    local dataOk = sock.state ~= "LISTEN" and sock.state ~= "CLOSED" and
        sock.state ~= "SYN_SENT"
    if dataOk and length > 0 then
        if seg.seq == sock.rcvNxt then
            -- in order thankfully
            if #seg.payload > 0 then
                if #sock.rcvQueue >= const.TCP_QUEUE_MAX then
                    table.remove(sock.rcvQueue, 1)
                    log("socket " .. tostring(sock.id) .. " queue overflow; dropped oldest")
                end
                sock.rcvQueue[#sock.rcvQueue + 1] = seg.payload
            end
            if hasFlag(flags, M.FLAGS.FIN) then
                finSeen = true
            end
            sock.rcvNxt = (sock.rcvNxt + length) % 4294967296
        end
        needAck = true
    end

    -- our partener divorced us :(
    if finSeen then
        sock.eof = true
        if sock.state == "ESTABLISHED" or sock.state == "SYN_RCVD" then
            sock.state = "CLOSE_WAIT"
        elseif sock.state == "FIN_WAIT_1" then
            sock.state = "CLOSING"
        elseif sock.state == "FIN_WAIT_2" then
            enterTimeWait(sock, nowNum)
        end
    end

    if sock.sndFin and sock.sndUna == sock.sndNxt then
        if sock.state == "FIN_WAIT_1" then
            sock.state = "FIN_WAIT_2"
        elseif sock.state == "LAST_ACK" then
            removeSocket(sock)
            return true
        elseif sock.state == "CLOSING" then
            enterTimeWait(sock, nowNum)
        end
    end

    if needAck then
        transmitEntry(sock, {
            seq = sock.sndNxt,
            flags = M.FLAGS.ACK,
            payload = "",
            len = 0,
            tries = 0,
        })
    end

    pumpRecv(sock)
    return true
end

-- Gee I wonder what this does
function M.receive(src, dst, seg)
    if type(seg) ~= "table" then
        return false
    end

    -- RST
    if hasFlag(seg.flags, M.FLAGS.RST) then
        local sock = findSocket(dst, src, seg.dport, seg.sport)
        if sock ~= nil and sock.state ~= "LISTEN" and sock.state ~= "CLOSED" then
            abortSocket(sock, "connection reset", true)
            return true
        end
        return false
    end

    -- How did we get here?
    if hasFlag(seg.flags, M.FLAGS.SYN) and not hasFlag(seg.flags, M.FLAGS.ACK) then
        local listener = findListener(dst, seg.dport)
        if listener == nil then
            sendRst(dst, src, seg.dport, seg.sport, 0,
                (seg.seq + segLen(seg)) % 4294967296)
            return false
        end
        return acceptSyn(listener, src, dst, seg)
    end

    local sock = findSocket(dst, src, seg.dport, seg.sport)
    if sock == nil then
        sendRst(dst, src, seg.dport, seg.sport,
            hasFlag(seg.flags, M.FLAGS.ACK) and seg.ack or 0,
            (seg.seq + segLen(seg)) % 4294967296)
        return false
    end
    return processSegment(sock, src, dst, seg)
end

-- most everything left is daemon's problem

-- Queue data for a socket
function M.send(sock, data)
    if type(data) ~= "string" or #data == 0 then
        return true -- nothing to do
    end
    if sock.state ~= "ESTABLISHED" and sock.state ~= "CLOSE_WAIT" then
        return nil, "not connected"
    end
    local pos = 1
    while pos <= #data do
        local piece = data:sub(pos, pos + sock.mss - 1)
        queueEntry(sock, M.FLAGS.ACK + M.FLAGS.PSH, piece)
        pos = pos + #piece
    end
    sockSend(sock, now())
    return true
end

function M.close(sock, waiter, nowNum)
    nowNum = nowNum or now()
    if sock.state == "LISTEN" or sock.state == "CLOSED" or
        sock.state == "SYN_SENT"
    then
        removeSocket(sock) -- nothing happened
        return true
    end
    if sock.state == "TIME_WAIT" then
        removeSocket(sock)
        return true
    end
    if sock.state == "ESTABLISHED" or sock.state == "SYN_RCVD" then
        queueEntry(sock, M.FLAGS.ACK + M.FLAGS.FIN, "")
        sock.sndFin = true
        sock.state = "FIN_WAIT_1"
    elseif sock.state == "CLOSE_WAIT" then
        queueEntry(sock, M.FLAGS.ACK + M.FLAGS.FIN, "")
        sock.sndFin = true
        sock.state = "LAST_ACK"
    else
        if sock.closeWaiter == nil then
            sock.closeWaiter = waiter
        end
        return "deferred"
    end
    sock.closeWaiter = waiter
    sockSend(sock, nowNum)
    return "deferred"
end

-- Steal
function M.popAccept(sock)
    if sock == nil or sock.acceptQueue == nil then
        return nil
    end
    while #sock.acceptQueue > 0 do
        local child = sockets[table.remove(sock.acceptQueue, 1)]
        if child ~= nil and child.listener == sock.id then
            child.accepted = true
            return child
        end
    end
    return nil
end

function M.shiftQueue(sock)
    if sock and #sock.rcvQueue > 0 then
        return table.remove(sock.rcvQueue, 1)
    end
    return nil
end

function M.setWaiter(sock, waiter)
    sock.waiter = waiter
    return true
end

function M.setAcceptWaiter(sock, waiter)
    sock.acceptWaiter = waiter
    return true
end

function M.cancelWaiter(sock, reqId)
    if sock and sock.waiter and (reqId == nil or sock.waiter.reqId == reqId) then
        sock.waiter = nil
        return true
    end
    return false
end

function M.cancelAcceptWaiter(sock, reqId)
    if sock and sock.acceptWaiter and (reqId == nil or sock.acceptWaiter.reqId == reqId) then
        sock.acceptWaiter = nil
        return true
    end
    return false
end

function M.abandon(id)
    local sock = sockets[id]
    if sock then
        abortSocket(sock, "owner gone")
    end
end

-- Retransmission
function M.tick(nowNum)
    for _, sock in pairs(sockets) do
        if sock.connectWaiter and nowNum >= sock.connectWaiter.deadline then
            abortSocket(sock, "timeout")
        elseif sock.closeWaiter and nowNum >= sock.closeWaiter.deadline then
            abortSocket(sock, "timeout")
        end

        local head = sock.sndQueue[1]
        if head and head.sent and head.deadline and nowNum >= head.deadline then
            head.tries = head.tries + 1
            if head.tries > const.TCP_RETRIES then
                abortSocket(sock, "timeout")
            else
                head.deadline = nowNum + retransmitTimeout(head.tries)
                transmitEntry(sock, head)
            end
        end

        sockSend(sock, nowNum) -- Hey its back!

        if sock.state == "TIME_WAIT" and nowNum >= (sock.timeWaitDeadline or 0) then
            removeSocket(sock)
        end
    end
end

function M.reset()
    sockets = {}
end

return M