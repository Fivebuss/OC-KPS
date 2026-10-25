-- /usr/lib/network/proto/ipv4.lua
-- Big guy, ipv4. ipv6 IS NEVER HAPPENING. Gross.
-- packet = { src, dst, proto, ttl, id, flags, offset, payload }

local const = require("network.const")
local wire = require("network.wire")
local address = require("network.address")

local M = {}

M.FLAG_MF = 4
M.FLAG_DF = 2 -- Dont fragment please

local localDeliver = nil
local forwardFn = nil
local isLocalFn = nil
local logFn = nil
local debugFn = nil
local errorFn = nil

function M.setLocalDeliver(fn) localDeliver = fn end

function M.setForward(fn) forwardFn = fn end

function M.setIsLocal(fn) isLocalFn = fn end

function M.setLog(fn) logFn = fn end

function M.setDebug(fn) debugFn = fn end

function M.setError(fn) errorFn = fn end

local function log(msg)
    if logFn then pcall(logFn, "ipv4: " .. tostring(msg)) end
end

local function debug(msg)
    if debugFn then pcall(debugFn, "ipv4: " .. tostring(msg)) end
end

local idCounter = 0

function M.nextId()
    idCounter = (idCounter + 1) % 65536
    return idCounter
end

local HEADER_LEN = 20

local function buildHeader(src, dst, proto, ttl, id, flags, offset, totalLen, checksum)
    local fo = flags * 8192 + offset
    return string.char(
        0x45, 0x00,
        math.floor(totalLen / 256) % 256, totalLen % 256,
        math.floor(id / 256) % 256, id % 256,
        math.floor(fo / 256) % 256, fo % 256,
        ttl % 256,
        proto % 256,
        math.floor(checksum / 256) % 256, checksum % 256,
        math.floor(src / 16777216) % 256, math.floor(src / 65536) % 256,
        math.floor(src / 256) % 256, src % 256,
        math.floor(dst / 16777216) % 256, math.floor(dst / 65536) % 256,
        math.floor(dst / 256) % 256, dst % 256
    )
end

local function headerChecksum(src, dst, proto, ttl, id, flags, offset, totalLen)
    local fo = flags * 8192 + offset
    local sum =
        0x4500 +
        totalLen +
        id +
        fo +
        ttl * 256 + proto +
        math.floor(src / 65536) % 65536 +
        src % 65536 +
        math.floor(dst / 65536) % 65536 +
        dst % 65536

    -- Make 32 16
    while sum > 65535 do
        sum = sum % 65536 + math.floor(sum / 65536)
    end
    return 65535 - sum
end

-- Create the full packet
function M.encodePacket(packet)
    local payload = packet.payload or ""
    local totalLen = HEADER_LEN + #payload
    local src = packet.src % 4294967296
    local dst = packet.dst % 4294967296
    local ttl = packet.ttl or 64
    local id = packet.id or 0
    local flags = packet.flags or 0
    local offset = packet.offset or 0
    local proto = packet.proto
    local checksum = headerChecksum(src, dst, proto, ttl, id, flags, offset, totalLen)
    return buildHeader(src, dst, proto, ttl, id, flags, offset, totalLen, checksum) .. payload
end

-- Packet becomes table
function M.decodePacket(data)
    if type(data) ~= "string" or #data < HEADER_LEN then
        return nil, "packet too short"
    end

    local version = math.floor(data:byte(1) / 16)
    local ihl = data:byte(1) % 16
    if version ~= 4 then
        return nil, "not IPv4"
    end
    if ihl ~= 5 then
        return nil, "unsupported header length " .. ihl
    end

    local len = wire.readU16(data, 3)
    local id = wire.readU16(data, 5)
    local flagsAndOffset = wire.readU16(data, 7)
    local ttl = data:byte(9)
    local proto = data:byte(10)
    local checksum = wire.readU16(data, 11)
    local src = wire.readU32(data, 13)
    local dst = wire.readU32(data, 17)

    if not (len and id and flagsAndOffset and ttl and proto and checksum and src and dst) then
        return nil, "truncated header"
    end

    local flags = math.floor(flagsAndOffset / 8192)
    local offset = flagsAndOffset % 8192

    local verify = headerChecksum(src, dst, proto, ttl, id, flags, offset, len)
    if checksum == 0 or checksum ~= verify then
        return nil, "header checksum mismatch"
    end

    if debugFn then
        debug("recv src=" .. (address.dotted(src) or "?") .. " dst=" ..
            (address.dotted(dst) or "?") .. " proto=" .. proto ..
            " id=" .. id .. " flags=" .. flags .. " off=" .. offset .. " len=" .. len)
    end

    if len < HEADER_LEN or len > #data then
        return nil, "bad total length"
    end

    return {
        src = src,
        dst = dst,
        proto = proto,
        ttl = ttl,
        id = id,
        flags = flags,
        offset = offset,
        payload = data:sub(HEADER_LEN + 1, len),
    }
end

-- MTU handling
function M.fragments(payload, mtu, id)
    local list = {}
    local maxPayload = mtu - HEADER_LEN
    if maxPayload < 8 then
        return nil, "mtu too small"
    end
    if #payload <= maxPayload then
        list[1] = { id = id, flags = 0, offset = 0, payload = payload }
        return list
    end
    local chunk = 8 * math.floor(maxPayload / 8)
    local pos = 1
    local offset = 0
    while pos <= #payload do
        local piece = payload:sub(pos, pos + chunk - 1)
        local last = pos + #piece > #payload
        list[#list + 1] = {
            id = id,
            flags = last and 0 or M.FLAG_MF,
            offset = offset,
            payload = piece,
        }
        pos = pos + chunk
        offset = offset + math.floor(#piece / 8)
    end
    return list
end

local fragBuffers = {}
local fragBufferCount = 0

local function bufferKey(src, dst, proto, id)
    -- combine src into dst
    local sdFold = (src + dst * 1000003) % 4294967296
    return sdFold * 16777216 + proto * 65536 + id
end

-- Assemble packet
function M.reassemble(packet, now, timeout)
    timeout = timeout or const.DEFAULTS.fragTimeout

    local mfSet = (packet.flags or 0) & M.FLAG_MF ~= 0
    local hasOffset = (packet.offset or 0) > 0

    if not mfSet and not hasOffset then
        -- unfragmented
        return {
            src = packet.src,
            dst = packet.dst,
            proto = packet.proto,
            payload = packet.payload,
        }
    end

    local key = bufferKey(packet.src, packet.dst, packet.proto, packet.id)
    local buffer = fragBuffers[key]
    if buffer == nil then
        if fragBufferCount >= const.FRAG_BUFFER_MAX then
            -- Buffer bounds
            local oldestKey, oldest = nil, nil
            for k, b in pairs(fragBuffers) do
                if oldest == nil or b.expires < oldest.expires then
                    oldestKey, oldest = k, b
                end
            end
            if oldestKey then
                fragBuffers[oldestKey] = nil
                fragBufferCount = fragBufferCount - 1
            end
        end
        buffer = {
            src = packet.src,
            dst = packet.dst,
            proto = packet.proto,
            expires = now + timeout,
            parts = {},
        }
        fragBuffers[key] = buffer
        fragBufferCount = fragBufferCount + 1
    end
    buffer.parts[packet.offset] = packet.payload

    if not mfSet and buffer.finalOffset == nil then
        buffer.finalOffset = packet.offset
    end
    if buffer.finalOffset == nil then
        return nil
    end

    local piece = buffer.parts[0]
    if piece == nil or #piece == 0 or #piece % 8 ~= 0 then
        return nil
    end
    local pieces = { piece }
    local offset = #piece / 8
    while offset < buffer.finalOffset do
        local next = buffer.parts[offset]
        if next == nil or #next == 0 or #next % 8 ~= 0 then
            return nil
        end
        pieces[#pieces + 1] = next
        offset = offset + #next / 8
    end
    local finalPiece = buffer.parts[buffer.finalOffset]
    if finalPiece == nil or #finalPiece == 0 then
        return nil
    end
    pieces[#pieces + 1] = finalPiece

    fragBuffers[key] = nil
    fragBufferCount = fragBufferCount - 1
    return {
        src = buffer.src,
        dst = buffer.dst,
        proto = buffer.proto,
        payload = table.concat(pieces),
    }
end

-- Expiry
function M.tick(now)
    local dropped = 0
    for key, buffer in pairs(fragBuffers) do
        if now >= buffer.expires then
            fragBuffers[key] = nil
            fragBufferCount = fragBufferCount - 1
            dropped = dropped + 1
            if errorFn then
                pcall(errorFn, {
                    reason = "frag-timeout",
                    packet = {
                        src = buffer.src,
                        dst = buffer.dst,
                        proto = buffer.proto
                    },
                    iface = nil
                })
            end
        end
    end
    return dropped
end

-- routes
-- { id, network, prefix, mask, gateway, metric, iface }

local routes = {}
local routeCounter = 0

-- Static
function M.addRoute(spec)
    local network, prefix = address.parseCIDR(spec.net)
    if network == nil then
        return nil, "invalid network: " .. tostring(spec.net)
    end
    local mask = address.prefixToMask(prefix)
    local gateway = spec.gateway or 0
    if type(gateway) ~= "number" or gateway < 0 or gateway % 1 ~= 0 then
        return nil, "invalid gateway"
    end

    routeCounter = routeCounter + 1
    local route = {
        id = routeCounter,
        network = network,
        prefix = prefix,
        mask = mask,
        gateway = gateway,
        metric = spec.metric or 1,
        iface = spec.iface,
        ptp = spec.ptp == true,
    }
    routes[#routes + 1] = route
    table.sort(routes, function(a, b)
        if a.prefix ~= b.prefix then
            return a.prefix > b.prefix
        end
        if a.metric ~= b.metric then
            return a.metric < b.metric
        end
        -- p2p wins
        if a.ptp ~= b.ptp then
            return a.ptp
        end
        return a.id < b.id
    end)
    return route
end

-- Prefix. Bigger wins
function M.lookup(dst)
    dst = dst % 4294967296
    for i = 1, #routes do
        local route = routes[i]
        if wire.band32(dst, route.mask) == route.network then
            return route
        end
    end
    return nil
end

function M.list()
    local copy = {}
    for i = 1, #routes do
        copy[i] = routes[i]
    end
    return copy
end

function M.delRoute(id)
    local keep, removed = {}, false
    for i = 1, #routes do
        if routes[i].id == id then
            removed = true
        else
            keep[#keep + 1] = routes[i]
        end
    end
    routes = keep
    return removed
end

-- Why multiple?
function M.delRoutesForIface(ifaceName)
    local keep, count = {}, 0
    for i = 1, #routes do
        if routes[i].iface == ifaceName then
            count = count + 1
        else
            keep[#keep + 1] = routes[i]
        end
    end
    routes = keep
    return count
end

function M.clearRoutes()
    routes = {}
end

-- Receive the ipv4
function M.receive(iface, data, now)
    local packet, reason = M.decodePacket(data)
    if packet == nil then
        log("drop: " .. tostring(reason))
        return false
    end
    local allowed = isLocalFn ~= nil and isLocalFn(packet.dst) or false
    if not allowed then
        if packet.dst == iface.addr then
            allowed = true
        elseif packet.dst == 4294967295 then -- 255.255.255.255
            allowed = true
        elseif iface.addr and iface.mask then
            if packet.dst == address.broadcastOf(iface.addr, iface.mask) then
                allowed = true
            end
        end
    end
    if not allowed then
        local fwdTtl = packet.ttl - 1
        if forwardFn == nil or fwdTtl <= 0 then
            if debugFn then
                debug("drop: dst " .. (address.dotted(packet.dst) or "?") ..
                    (fwdTtl <= 0 and " (ttl expired)" or " (no forwarder)"))
            end
            if fwdTtl <= 0 and errorFn and forwardFn then
                pcall(errorFn, {
                    reason = "ttl",
                    packet = packet,
                    iface = iface
                })
            end
            return false
        end
        if debugFn then
            debug("forward: dst " .. (address.dotted(packet.dst) or "?"))
        end
        if (packet.flags or 0) % 4 >= 2 or
            (#packet.payload + HEADER_LEN) > iface.mtu
        then
            if errorFn then
                pcall(errorFn, {
                    reason = "frag-needed",
                    packet = packet,
                    iface = iface
                })
            end
            return false
        end
        pcall(forwardFn, {
            src = packet.src,
            dst = packet.dst,
            proto = packet.proto,
            payload = packet.payload,
            id = packet.id,
            flags = packet.flags,
            offset = packet.offset,
            ttl = fwdTtl,
            inIface = iface and iface.name or nil,
        })
        return false
    end

    local msg = M.reassemble(packet, now)
    if msg == nil then
        return true -- dont do anything
    end

    if localDeliver then
        local ok, err = pcall(localDeliver, msg)
        if not ok then
            log("local delivery failed: " .. tostring(err))
            return false
        end
    end
    return true
end

function M.reset()
    fragBuffers = {}
    fragBufferCount = 0
end

function M.resetAll()
    fragBuffers = {}
    fragBufferCount = 0
    routes = {}
end

return M
