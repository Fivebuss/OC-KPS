-- /usr/lib/network/proto/arp.lua
-- ARP cache. Yay

local const = require("network.const")
local wire = require("network.wire")

local M = {}

M.OPERATION = { REQUEST = 1, REPLY = 2 }

local requestFn = nil
local flushFn = nil
local logFn = nil

function M.setRequestSender(fn) requestFn = fn end

function M.setFlush(fn) flushFn = fn end

function M.setLog(fn) logFn = fn end

local function log(msg)
    if logFn then
        pcall(logFn, "arp: " .. tostring(msg))
    end
end

-- htype u16 | ptype u16 | hlen u8 | plen u8 | oper u16 |
-- sha[hlen] | spa[u32] | tha[hlen] | tpa[u32]

function M.encode(oper, sha, spa, tha, tpa)
    local hlen = #sha
    if #tha ~= hlen then
        return nil, "hardware address length mismatch"
    end
    return table.concat({
        wire.packU16(const.HTYPE_ETHERNET),   -- htype: ethernet
        wire.packU16(const.ETHER_TYPES.IPv4), -- ptype: IPv4
        wire.packU8(hlen),
        wire.packU8(4),
        wire.packU16(oper),
        sha,
        wire.packU32(spa % 4294967296),
        tha,
        wire.packU32(tpa % 4294967296),
    })
end

-- Bigass if chain
function M.decode(data)
    if type(data) ~= "string" then
        return nil, "frame must be a string"
    end
    local htype, pos = wire.readU16(data, 1)
    if not htype then return nil, "short frame" end
    local ptype
    ptype, pos = wire.readU16(data, pos)
    if not ptype then return nil, "short frame" end
    local hlen
    hlen, pos = wire.readU8(data, pos)
    if not hlen then return nil, "short frame" end
    local plen
    plen, pos = wire.readU8(data, pos)
    if not plen then return nil, "short frame" end
    local oper
    oper, pos = wire.readU16(data, pos)
    if not oper then return nil, "short frame" end
    if hlen == 0 or hlen > 64 or plen ~= 4 then
        return nil, "unsupported address lengths"
    end
    if #data - pos + 1 < 2 * hlen + 2 * plen then
        return nil, "short frame"
    end

    local sha = data:sub(pos, pos + hlen - 1)
    local spa
    spa, pos = wire.readU32(data, pos + hlen)
    local tha = data:sub(pos, pos + hlen - 1)
    local tpa
    tpa, pos = wire.readU32(data, pos + hlen)

    if not spa or not tpa then
        return nil, "short frame"
    end

    return {
        htype = htype,
        ptype = ptype,
        oper = oper,
        sha = sha,
        spa = spa,
        tha = tha,
        tpa = tpa,
    }
end

-- cache
-- [ipNum] = { hw = string, iface = ifaceName, expires = uptime }

local cache = {}

-- Gives cache for ip
function M.lookup(ip, now)
    local entry = cache[ip]
    if entry == nil then
        return nil
    end
    if now and entry.expires and now >= entry.expires then
        cache[ip] = nil
        return nil
    end
    return entry.hw
end

function M.list()
    local out = {}
    for ip, entry in pairs(cache) do
        out[#out + 1] = { ip = ip, hw = entry.hw, iface = entry.iface, expires = entry.expires }
    end
    return out
end

function M.flushCache()
    cache = {}
end

function M.forgetIface(ifaceName)
    local keep = {}
    for ip, entry in pairs(cache) do
        if entry.iface ~= ifaceName then
            keep[ip] = entry
        end
    end
    cache = keep
end

local function cachePut(ip, hw, ifaceName, now, expiry)
    cache[ip] = { hw = hw, iface = ifaceName, expires = now + (expiry or const.DEFAULTS.arpExpire) }
end

-- Queues look like this (thanks ai)
-- [ipNum] = {
--   iface = iface table the request went out on,
--   tries = number, nextAttempt = uptime, deadline = uptime,
--   items = { { iface = ifaceTable, src = ipNum, encode = fn(src) : payload } }
-- }

local pending = {}

local function defaultDeadline()
    return const.DEFAULTS.arpRetries * const.DEFAULTS.arpTimeout
end

-- Queue unresolved thing
-- opts are { timeout, retries, deadline }
function M.enqueue(ip, iface, entry, now, opts)
    if type(ip) ~= "number" or type(iface) ~= "table" then
        return nil, "invalid arp enqueue"
    end
    opts = opts or {}
    local timeout = opts.timeout or const.DEFAULTS.arpTimeout
    local queue = pending[ip]

    if queue == nil then
        queue = {
            iface = iface,
            tries = 0,
            nextAttempt = 0,
            deadline = now + (opts.deadline or defaultDeadline()),
            items = {},
        }
        pending[ip] = queue
    end
    if queue.nextAttempt == nil then
        queue.nextAttempt = 0
    end

    if #queue.items >= const.ARP_QUEUE_MAX then
        table.remove(queue.items, 1)
        log("pending queue overflow for " .. tostring(ip) .. "; dropped oldest")
    end
    queue.items[#queue.items + 1] = entry
    return "queued"
end

-- Get rid of arp request
function M.kick(iface, ip, now, timeout)
    local queue = pending[ip]
    if queue == nil or queue.tries > 0 then
        return false
    end
    queue.tries = 1
    queue.nextAttempt = now + (timeout or const.DEFAULTS.arpTimeout)
    if requestFn then
        local ok, err = pcall(requestFn, queue.iface, ip)
        if not ok then
            log("request send failed: " .. tostring(err))
        end
    end
    return true
end

-- Expiry
function M.tick(now, opts)
    opts = opts or {}
    local retries = opts.retries or const.DEFAULTS.arpRetries
    local timeout = opts.timeout or const.DEFAULTS.arpTimeout

    for ip, queue in pairs(pending) do
        if now >= queue.deadline then
            local dropped = #queue.items
            pending[ip] = nil
            log("no arp response for " .. tostring(ip) .. "; " .. dropped .. " packet(s) dropped")
        elseif queue.tries >= retries then
            pending[ip] = nil
            log("arp gave up on " .. tostring(ip))
        elseif now >= queue.nextAttempt then
            queue.tries = queue.tries + 1
            queue.nextAttempt = now + timeout
            if requestFn then
                local ok, err = pcall(requestFn, queue.iface, ip)
                if not ok then
                    log("retry send failed: " .. tostring(err))
                end
            end
        end
    end
end

--Hand resolved items to the stack. Returns delivered count
function M.flush(ip, hw)
    local queue = pending[ip]
    if queue == nil then
        return 0
    end
    pending[ip] = nil
    local count = 0
    if flushFn then
        for _, entry in ipairs(queue.items) do
            local ok, err = pcall(flushFn, entry, hw)
            if ok then
                count = count + 1
            else
                log("flush item failed: " .. tostring(err))
            end
        end
    end
    return count
end

--Handle an incoming decoded frame. iface: receiving interface table
--(needs .addr, .hw, .name). now: uptime, expiry: cache lifetime seconds.
function M.receive(iface, frame, now, expiry)
    if frame == nil then
        return false
    end
    local ifaceName = iface and iface.name or nil

    if frame.oper == M.OPERATION.REQUEST then
        -- opportunistic: cache the sender pair so our reply needs no lookup
        if frame.spa and frame.spa ~= 0 and frame.sha and #frame.sha > 0 then
            cachePut(frame.spa, frame.sha, ifaceName, now, expiry)
        end
        -- answer only when we own the requested address on this interface
        if iface and iface.addr and frame.tpa == iface.addr then
            local reply = M.encode(
                M.OPERATION.REPLY,
                iface.hw,   -- sha: our hardware
                iface.addr, -- spa: the address they asked about
                frame.sha,  -- tha: requester hardware
                frame.spa   -- tpa: requester protocol address
            )
            if reply then
                if requestFn then
                    local ok, err = pcall(requestFn, iface, frame.spa, frame.sha, reply)
                    if not ok then
                        log("reply send failed: " .. tostring(err))
                    end
                end
            end
        end
        return true
    end

    if frame.oper == M.OPERATION.REPLY then
        if frame.spa and frame.sha and #frame.sha > 0 then
            cachePut(frame.spa, frame.sha, ifaceName, now, expiry)
            M.flush(frame.spa, frame.sha)
        end
        return true
    end

    return false
end

--Wipe all protocol state (daemon shutdown).
function M.reset()
    cache = {}
    pending = {}
end

return M
