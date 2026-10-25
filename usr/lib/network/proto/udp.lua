-- /usr/lib/network/proto/udp.lua
-- UDP, sort of compliant? I hope?

-- Socket records look like this (thanks ai V)
--   { id, laddr (num, 0 = wildcard), lport, raddr (num, 0 = wildcard),
--     rport (0 = wildcard), owner (client pid), queue = { { from, port, data } },
--     waiter = { pid, reqId } | nil }


local const = require("network.const")
local wire = require("network.wire")

local M = {}

local socketCounter = 0
local sockets = {} -- [id] = socket record

local notifyFn = nil
local logFn = nil

function M.setNotify(fn) notifyFn = fn end
function M.setLog(fn) logFn = fn end

local function log(msg)
    if logFn then pcall(logFn, "udp: " .. tostring(msg)) end
end

-- Makes it
function M.encodeDatagram(sport, dport, payload, src, dst)
    local length = 8 + #payload
    local zeroed = table.concat({
        wire.packU16(sport),
        wire.packU16(dport),
        wire.packU16(length),
        wire.packU16(0),
        payload,
    })
    local pseudo = table.concat({
        wire.packU32(src % 4294967296),
        wire.packU32(dst % 4294967296),
        wire.packU8(0),
        wire.packU8(const.PROTOCOLS.UDP),
        wire.packU16(length),
        zeroed,
    })
    local checksum = wire.checksum(pseudo)
    return table.concat({
        wire.packU16(sport),
        wire.packU16(dport),
        wire.packU16(length),
        wire.packU16(checksum),
        payload,
    })
end

-- Get a table back
function M.decodeDatagram(data, src, dst)
    if type(data) ~= "string" or #data < 8 then
        return nil, "datagram too short"
    end
    local sport = wire.readU16(data, 1)
    local dport = wire.readU16(data, 3)
    local length = wire.readU16(data, 5)
    local checksum = wire.readU16(data, 7)
    if not (sport and dport and length and checksum) then
        return nil, "truncated header"
    end
    if length < 8 or #data < length then
        return nil, "bad length"
    end

    if checksum ~= 0 then
        local pseudo = table.concat({
            wire.packU32(src % 4294967296),
            wire.packU32(dst % 4294967296),
            wire.packU8(0),
            wire.packU8(const.PROTOCOLS.UDP),
            wire.packU16(length),
            data:sub(1, length),
        })
        if wire.checksum(pseudo) ~= 0 then
            return nil, "checksum mismatch"
        end
    end

    return {
        sport = sport,
        dport = dport,
        payload = length > 8 and data:sub(9, length) or "",
    }
end

function M.nextSocketId()
    socketCounter = socketCounter + 1
    return socketCounter
end

function M.get(id)
    return sockets[id]
end

function M.list()
    local out = {}
    for id, sock in pairs(sockets) do
        out[#out + 1] = sock
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function M.count()
    local n = 0
    for _ in pairs(sockets) do n = n + 1 end
    return n
end

function M.remove(id)
    local sock = sockets[id]
    if sock then
        sockets[id] = nil
    end
    return sock
end

function M.removeOwnedBy(pid)
    local count = 0
    for id, sock in pairs(sockets) do
        if sock.owner == pid then
            sockets[id] = nil
            count = count + 1
        end
    end
    return count
end

-- Find socket
function M.removeBoundTo(addrNum)
    local count = 0
    for id, sock in pairs(sockets) do
        if sock.laddr == addrNum then
            sockets[id] = nil
            count = count + 1
        end
    end
    return count
end

-- Wildcard problems
local function tuplesConflict(a, b)
    local function eq(v1, v2)
        return v1 == v2 or v1 == 0 or v2 == 0
    end
    return eq(a.laddr, b.laddr) and eq(a.lport, b.lport) and
        eq(a.raddr, b.raddr) and eq(a.rport, b.rport)
end

-- Binds, hopefully it rejects problematic things
function M.bind(laddr, lport, opts)
    opts = opts or {}

    if laddr == nil then
        laddr = 0
    end
    if type(laddr) ~= "number" or laddr < 0 or laddr % 1 ~= 0 or laddr > 4294967295 then
        return nil, "invalid address"
    end
    if type(lport) ~= "number" or lport < 0 or lport % 1 ~= 0 or lport > 65535 then
        return nil, "invalid port"
    end

    -- Stop trying to steal daemon's port
    if laddr == 2130706433 and lport == const.CONTROL_PORT then -- 127.0.0.1
        return nil, "reserved endpoint"
    end

    local candidate = {
        laddr = laddr,
        lport = lport,
        raddr = opts.raddr or 0,
        rport = opts.rport or 0,
    }

    -- Wildcard goes first
    if candidate.lport ~= 0 then
        for _, sock in pairs(sockets) do
            if tuplesConflict(candidate, sock) then
                return nil, "address already in use"
            end
        end
    else
        for _ = 1, 4 do
            local port = math.random(const.EPHEMERAL_PORT_MIN, const.EPHEMERAL_PORT_MAX)
            local partial = { laddr = candidate.laddr, lport = port, raddr = candidate.raddr, rport = candidate.rport }
            local conflict = false
            for _, sock in pairs(sockets) do
                if tuplesConflict(partial, sock) then
                    conflict = true
                    break
                end
            end
            if not conflict then
                candidate.lport = port
                break
            end
        end
        if candidate.lport == 0 then
            return nil, "no free ephemeral port"
        end
    end

    local id = M.nextSocketId()
    local sock = {
        id = id,
        laddr = candidate.laddr,
        lport = candidate.lport,
        raddr = candidate.raddr,
        rport = candidate.rport,
        owner = opts.owner,
        queue = {},
        waiter = nil,
    }
    sockets[id] = sock
    return sock
end

function M.connect(id, raddr, rport)
    local sock = sockets[id]
    if sock == nil then
        return nil, "no such socket"
    end
    if type(raddr) ~= "number" or raddr < 0 or raddr % 1 ~= 0 then
        return nil, "invalid address"
    end
    if type(rport) ~= "number" or rport <= 0 or rport % 1 ~= 0 or rport > 65535 then
        return nil, "invalid port"
    end

    local candidate = { laddr = sock.laddr, lport = sock.lport, raddr = raddr, rport = rport }
    for socketId, other in pairs(sockets) do
        if socketId ~= id and tuplesConflict(candidate, other) then
            return nil, "address already in use"
        end
    end

    sock.raddr = raddr
    sock.rport = rport
    return sock
end

local function matchScore(sock, dst, src, dstPort, srcPort)
    if sock.lport ~= dstPort then return nil end
    if sock.laddr ~= dst and sock.laddr ~= 0 then return nil end
    if sock.raddr ~= src and sock.raddr ~= 0 then return nil end
    if sock.rport ~= srcPort and sock.rport ~= 0 then return nil end

    local score = 0
    if sock.laddr ~= 0 then score = score + 8 end
    if sock.raddr ~= 0 then score = score + 4 end
    if sock.rport ~= 0 then score = score + 2 end
    return score
end

function M.findSocket(dst, src, dstPort, srcPort)
    local best, bestScore
    for id, sock in pairs(sockets) do
        local score = matchScore(sock, dst, src, dstPort, srcPort)
        if score and (best == nil or score > bestScore) then
            best, bestScore = sock, score
        end
    end
    return best
end

-- Send a datagram to queue
function M.deliver(sock, src, srcPort, payload)
    if #sock.queue >= const.UDP_QUEUE_MAX then
        table.remove(sock.queue, 1)
        log("socket " .. tostring(sock.id) .. " queue overflow; dropped oldest")
    end
    sock.queue[#sock.queue + 1] = {
        from = src,
        port = srcPort,
        data = payload,
    }

    local waiter = sock.waiter
    if waiter then
        local entry = table.remove(sock.queue, 1)
        sock.waiter = nil
        if notifyFn then
            pcall(notifyFn, waiter.pid, {
                network = true,
                kind = "data",
                pid = waiter.pid,
                ref = sock.id,
                data = entry.data,
                from = entry.from,
                port = entry.port,
            })
        end
    end
    return true
end

function M.shiftQueue(sock)
    if sock and #sock.queue > 0 then
        return table.remove(sock.queue, 1)
    end
    return nil
end

function M.setWaiter(sock, waiter)
    sock.waiter = waiter
    return true
end

function M.cancelWaiter(sock, reqId)
    if sock and sock.waiter and (reqId == nil or sock.waiter.reqId == reqId) then
        sock.waiter = nil
        return true
    end
    return false
end

function M.reset()
    sockets = {}
end

return M
