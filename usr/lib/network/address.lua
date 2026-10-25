-- /usr/lib/network/address.lua
-- Deals with all the math around addresses

local wire = require("network.wire")

local M = {}

-- Makes X.X.X.X into 32 bit number. Yes, 32 bit in lua. This is aweful
function M.parse(dotted)
    if type(dotted) ~= "string" then
        return nil, "address must be a string"
    end
    local a, b, c, d = dotted:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return nil, "invalid IPv4 address: " .. dotted
    end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a > 255 or b > 255 or c > 255 or d > 255 then
        return nil, "invalid IPv4 address: " .. dotted
    end
    return a * 16777216 + b * 65536 + c * 256 + d
end

M.fromString = M.parse

function M.dotted(num)
    if type(num) ~= "number" then
        return nil, "address must be a number"
    end
    num = num % 4294967296
    return string.format(
        "%d.%d.%d.%d",
        math.floor(num / 16777216) % 256,
        math.floor(num / 65536) % 256,
        math.floor(num / 256) % 256,
        num % 256
    )
end

M.toString = M.dotted

-- CIDR / masks, /32 is assumed if its not there
function M.parseCIDR(cidr)
    if type(cidr) ~= "string" then
        return nil, "cidr must be a string"
    end
    local addrPart, prefixPart = cidr:match("^([^/]+)/(%d+)$")
    if not addrPart then
        addrPart = cidr:match("^([^/]+)$")
        prefixPart = nil
    end
    if not addrPart then
        return nil, "invalid cidr: " .. cidr
    end
    local addr, reason = M.parse(addrPart)
    if not addr then
        return nil, reason
    end
    local prefix = 32
    if prefixPart then
        prefix = tonumber(prefixPart) % 100000
        if prefix > 32 then
            return nil, "invalid prefix in cidr: " .. cidr
        end
    end
    return addr, prefix
end

-- netmask
local _prefixToMask = {}
do
    _prefixToMask[0] = 0
    for p = 1, 31 do
        -- 2^(32-p)
        _prefixToMask[p] = 4294967296 - (2 ^ (32 - p))
    end
    _prefixToMask[32] = 4294967295
end

function M.prefixToMask(prefix)
    if type(prefix) ~= "number" or prefix % 1 ~= 0 or prefix < 0 or prefix > 32 then
        return nil, "invalid prefix"
    end
    return _prefixToMask[prefix]
end

function M.maskToPrefix(mask)
    if type(mask) ~= "number" or mask < 0 or mask % 1 ~= 0 then
        return nil, "invalid mask"
    end
    if mask == 0 then return 0 end
    if mask == 4294967295 then return 32 end
    -- hostBits = wire.not32(mask) + 1
    local hostBits = (4294967295 - mask % 4294967296) + 1
    local prefix = 32 - math.floor(math.log(hostBits) / math.log(2) + 0.5)

    if prefix < 0 or prefix > 32 or _prefixToMask[prefix] ~= mask % 4294967296 then
        return nil, "non-contiguous mask"
    end
    return prefix
end

function M.networkOf(addr, mask)
    return wire.band32(addr, mask)
end

function M.broadcastOf(addr, mask)
    return M.networkOf(addr, mask) + wire.not32(mask) % 4294967296
end

function M.isLoopback(addr)
    if type(addr) ~= "number" then
        return false
    end
    return math.floor(addr / 16777216) == 127
end

return M
