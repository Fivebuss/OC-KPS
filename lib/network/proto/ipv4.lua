-- /lib/network/proto/ipv4.lua
-- Big guy, ipv4. ipv6 IS NEVER HAPPENING. Gross.
-- packet = { src, dst, proto, ttl, id, flags, offset, payload }

local const = require("network.const")
local wire = require("network.wire")
local address = require("network.address")

local M = {}

M.FLAG_MF = 4
M.FLAG_DF = 2 -- Dont fragment please

local localDeliver = nil
local logFn = nil
local debugFn = nil

function M.setLocalDeliver(fn) localDeliver = fn end

function M.setLog(fn) logFn = fn end

function M.setDebug(fn) debugFn = fn end

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

local function headerChecksum(src, dst, proto, ttl, id, flags, offset, totalLen)
    local head = table.concat({
        string.char(0x45, 0x00),
        wire.packU16(totalLen),
        wire.packU16(id),
        wire.packU16(flags * 8192 + offset),
        wire.packU8(ttl),
        wire.packU8(proto),
        wire.packU16(0),
        wire.packU32(src % 4294967296),
        wire.packU32(dst % 4294967296),
    })
    return wire.checksum(head)
end

-- Create the full packet
function M.encodePacket(packet)
    local totalLen = HEADER_LEN + #(packet.payload or "")
    local checksum = headerChecksum(
        packet.src, packet.dst, packet.proto,
        packet.ttl or 64, packet.id or 0,
        packet.flags or 0, packet.offset or 0, -- offset in 8-byte, kindly
        totalLen
    )
    return table.concat({
        string.char(0x45, 0x00),
        wire.packU16(totalLen),
        wire.packU16(packet.id or 0),
        wire.packU16((packet.flags or 0) * 8192 + (packet.offset or 0)),
        wire.packU8(packet.ttl or 64),
        wire.packU8(packet.proto),
        wire.packU16(checksum),
        wire.packU32(packet.src % 4294967296),
        wire.packU32(packet.dst % 4294967296),
        packet.payload or "",
    })
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
    if checksum ~= 0 and checksum ~= verify then
        -- Checksum of 0?
        return nil, "header checksum mismatch"
    end
    debug("recv src=" .. (address.dotted(src) or "?") .. " dst=" ..
        (address.dotted(dst) or "?") .. " proto=" .. proto ..
        " id=" .. id .. " flags=" .. flags .. " off=" .. offset .. " len=" .. len)

    if len < HEADER_LEN or len > #data then
        return nil, "bad total length"
    end

    if ttl <= 0 then
        return nil, "ttl expired"
    end

    return {
        src = src,
        dst = dst,
        proto = proto,
        ttl = ttl - 1, -- hop
        id = id,
        flags = flags,
        offset = offset,
        payload = data:sub(HEADER_LEN + 1, len),
    }
end

-- MTU handliing
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

local function bufferCount()
    local n = 0
    for _ in pairs(fragBuffers) do n = n + 1 end
    return n
end

local function bufferKey(packet)
    return tostring(packet.src) .. "/" .. tostring(packet.dst) .. "/" .. tostring(packet.id)
end

-- Assemble packet
function M.reassemble(packet, now, timeout)
    timeout = timeout or const.DEFAULTS.fragTimeout
    local mfSet = math.floor((packet.flags or 0) / M.FLAG_MF) % 2 == 1
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

    local key = bufferKey(packet)
    local buffer = fragBuffers[key]
    if buffer == nil then
        if bufferCount() >= const.FRAG_BUFFER_MAX then
            -- Buffer bounds
            local oldestKey, oldest = nil, nil
            for k, b in pairs(fragBuffers) do
                if oldest == nil or b.expires < oldest.expires then
                    oldestKey, oldest = k, b
                end
            end
            if oldestKey then
                fragBuffers[oldestKey] = nil
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
    end
    buffer.parts[packet.offset] = packet.payload

    if mfSet then
        return nil
    end

    -- The packets
    local pieces = {}
    local offset = 0
    while true do -- ew
        local piece = buffer.parts[offset]
        if piece == nil or piece == 0 then
            return nil
        end
        pieces[#pieces + 1] = piece
        if #piece % 8 ~= 0 or piece == 0 then
            break
        end
        offset = offset + math.floor(#piece / 8)
        coroutine.yield()
    end

    fragBuffers[key] = nil
    return {
        src = buffer.src,
        dst = buffer.dst,
        proto = buffer.proto,
        payload = table.concat(pieces),
    }
end

-- Expiry
function M.tick(now)
    local keep, dropped = {}, 0
    for key, buffer in pairs(fragBuffers) do
        if now >= buffer.expires then
            dropped = dropped + 1
        else
            keep[key] = buffer
        end
    end
    fragBuffers = keep
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
    }
    routes[#routes + 1] = route
    table.sort(routes, function(a, b)
        if a.prefix ~= b.prefix then
            return a.prefix > b.prefix
        end
        if a.metric ~= b.metric then
            return a.metric < b.metric
        end
        return a.id < b.id
    end)
    return route
end

-- Prefix. Bigger wins
function M.lookup(dst)
    local best, bestMetric, bestId
    for i = 1, #routes do
        local route = routes[i]
        if wire.band32(dst % 4294967296, route.mask) == route.network then
            if best == nil or route.prefix > best.prefix or
                (route.prefix == best.prefix and route.metric < bestMetric) or
                (route.prefix == best.prefix and route.metric == bestMetric and route.id < bestId)
            then
                best, bestMetric, bestId = route, route.metric, route.id
            end
        end
    end
    return best
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

    -- Acceptance test
    local allowed = false
    if packet.dst == iface.addr then
        allowed = true
    elseif packet.dst == 4294967295 then -- 255.255.255.255
        allowed = true
    elseif iface.addr and iface.mask then
        if packet.dst == address.broadcastOf(iface.addr, iface.mask) then
            allowed = true
        end
    end
    if not allowed then
        debug("drop: dst " .. (address.dotted(packet.dst) or "?") .. " is not ours; no forwarding")
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
end

function M.resetAll()
    fragBuffers = {}
    routes = {}
end

return M
