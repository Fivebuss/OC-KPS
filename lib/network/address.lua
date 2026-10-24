-- /lib/network/address.lua
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
function M.prefixToMask(prefix)
    if type(prefix) ~= "number" or prefix % 1 ~= 0 or prefix < 0 or prefix > 32 then
        return nil, "invalid prefix"
    end
    local mask = 0
    for i = 1, prefix do
        mask = mask + 2 ^ (32 - i)
    end
    return mask
end

function M.maskToPrefix(mask)
    if type(mask) ~= "number" or mask < 0 or mask % 1 ~= 0 then
        return nil, "invalid mask"
    end
    if mask == 0 then
        return 0
    end
    local prefix = 0
    for i = 31, 0, -1 do
        if math.floor(mask / 2 ^ i) % 2 == 1 then
            prefix = prefix + 1
        else
            if mask % 2 ^ i ~= 0 then
                return nil, "non-contiguous mask"
            end
            return prefix
        end
    end
    return 32
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
