-- /usr/lib/network/proto/icmp.lua
-- ICMP echo basically

local const = require("network.const")
local wire = require("network.wire")

local M = {}

M.TYPE = {
    ECHO_REPLY    = 0,
    DEST_UNREACH  = 3,
    ECHO_REQUEST  = 8,
    TTL_EXCEEDED  = 11,
    PARAM_PROBLEM = 12,
}

local sendIPFn = nil
local notifyFn = nil
local logFn = nil

function M.setSendIP(fn) sendIPFn = fn end

function M.setNotify(fn) notifyFn = fn end

function M.setLog(fn) logFn = fn end

local function log(msg)
    if logFn then pcall(logFn, "icmp: " .. tostring(msg)) end
end

-- it looks like: type u8 | code u8 | checksum u16 | rest u32 | payload

-- Big header
local function buildHeader(itype, code, checksum, rest)
    rest = (rest or 0) % 4294967296
    return string.char(
        itype % 256,
        code % 256,
        math.floor(checksum / 256) % 256, checksum % 256,
        math.floor(rest / 16777216) % 256, math.floor(rest / 65536) % 256,
        math.floor(rest / 256) % 256, rest % 256
    )
end

-- Make the message
function M.encode(itype, code, icmpId, seq, payload)
    local rest = (icmpId % 65536) * 65536 + (seq % 65536)
    return M.encodeError(itype, code, rest, payload)
end

-- Next hop thing
function M.encodeError(itype, code, rest, embedded)
    embedded = embedded or ""
    -- Checksum trick?
    local zeroed = buildHeader(itype, code, 0, rest) .. embedded
    local checksum = wire.checksum(zeroed)
    return zeroed:sub(1, 2) .. string.char(
        math.floor(checksum / 256) % 256, checksum % 256
    ) .. zeroed:sub(5)
end

-- Decode this nonsense
function M.decode(data)
    if type(data) ~= "string" or #data < 8 then
        return nil, "message too short"
    end
    local itype = data:byte(1)
    local code = data:byte(2)
    local checksum = wire.readU16(data, 3)
    local rest = wire.readU32(data, 5)
    if not checksum or not rest then
        return nil, "truncated header"
    end
    local verify = wire.checksum(data)
    if verify ~= 0 then
        return nil, "checksum mismatch"
    end

    local icmpId = math.floor(rest / 65536) % 65536
    local seq = rest % 65536
    local payload = #data > 8 and data:sub(9) or ""
    return { itype = itype, code = code, icmpId = icmpId, seq = seq, payload = payload }
end

local pool = {}
local poolCount = 0 -- tracked so poolSize() needs no iteration

local function poolKey(src, dst, icmpId, seq)
    local sdFold = (src + dst * 1000003) % 4294967296
    return sdFold * 4294967296 + icmpId * 65536 + seq
end

function M.poolSize()
    return poolCount
end

-- Keep an eye on request though
function M.beginRequest(spec, now)
    local src = spec.src or 0
    local key = poolKey(src, spec.dst, spec.icmpId, spec.seq)
    pool[key] = {
        clientPid = (spec.ipcRequest or {}).pid,
        reqId = (spec.ipcRequest or {}).id,
        src = src,
        dst = spec.dst,
        icmpId = spec.icmpId,
        seq = spec.seq,
        payload = spec.payload,
        deadline = now + (spec.timeout or const.DEFAULTS.icmpTimeout),
    }
    poolCount = poolCount + 1
    return key
end

local function removeKey(key)
    local entry = pool[key]
    if entry then
        pool[key] = nil
        poolCount = poolCount - 1
    end
    return entry
end

-- Expiry
function M.tick(now)
    for key, entry in pairs(pool) do
        if now >= entry.deadline then
            pool[key] = nil
            poolCount = poolCount - 1
            if notifyFn and entry.clientPid then
                local ok, err = pcall(notifyFn, entry.clientPid, entry.reqId, {
                    op = "ping",
                    type = "timeout",
                    dst = entry.dst,
                    id = entry.icmpId,
                    seq = entry.seq,
                    payload = entry.payload,
                })
                if not ok then log("notify failed: " .. tostring(err)) end
            end
        end
    end
end

-- Handle ICMP
function M.receive(src, dst, msg)
    if msg == nil then
        return false
    end

    if msg.itype == M.TYPE.ECHO_REPLY and msg.code == 0 then
        local key = poolKey(dst, src, msg.icmpId, msg.seq)
        local entry = removeKey(key)
        if entry == nil then
            -- not ours (or tiemed out)
            return false
        end
        if notifyFn and entry.clientPid then
            local ok, err = pcall(notifyFn, entry.clientPid, entry.reqId, {
                op = "ping",
                type = "reply",
                dst = entry.dst,
                id = msg.icmpId,
                seq = msg.seq,
                payload = msg.payload,
            })
            if not ok then log("notify failed: " .. tostring(err)) end
        end
        return true
    end

    if msg.itype == M.TYPE.ECHO_REQUEST and msg.code == 0 then
        -- answer echo requests for us
        local reply = M.encode(M.TYPE.ECHO_REPLY, 0, msg.icmpId, msg.seq, msg.payload or "")
        if reply and sendIPFn then
            local ok, sent, sErr = pcall(sendIPFn, {
                src = dst,
                dst = src,
                proto = const.PROTOCOLS.ICMP,
                payload = reply,
            })
            if not ok or not sent then
                log("echo reply send failed: " .. tostring(sErr or (not ok and sent or nil)))
            end
        end
        return true
    end

    if msg.itype == M.TYPE.DEST_UNREACH or msg.itype == M.TYPE.TTL_EXCEEDED then
        local emb = msg.payload
        if type(emb) == "string" and #emb >= 28 and emb:byte(10) == const.PROTOCOLS.ICMP then
            local eSrc = wire.readU32(emb, 13)
            local eDst = wire.readU32(emb, 17)
            local rest = wire.readU32(emb, 25)
            if eSrc and eDst and rest then
                local eId = math.floor(rest / 65536) % 65536
                local eSeq = rest % 65536
                local entry = removeKey(poolKey(eSrc, eDst, eId, eSeq))
                if entry ~= nil and notifyFn and entry.clientPid then
                    pcall(notifyFn, entry.clientPid, entry.reqId, {
                        op = "ping",
                        type = "error",
                        dst = entry.dst,
                        id = eId,
                        seq = eSeq,
                        payload = entry.payload,
                    })
                end
            end
        end
        return false
    end

    return false
end

function M.dropRequest(src, dst, icmpId, seq)
    return removeKey(poolKey(src, dst, icmpId, seq)) ~= nil
end

function M.poolList()
    local out = {}
    for _, entry in pairs(pool) do
        out[#out + 1] = entry
    end
    return out
end

function M.reset()
    pool = {}
    poolCount = 0
end

return M
