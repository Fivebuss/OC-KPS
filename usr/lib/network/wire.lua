-- /usr/lib/network/wire.lua
-- Big-endian byte packing/unpacking and checksum. What a mouthful. I just snatched it lmao

local M = {}

function M.packU8(value)
    return string.char(value % 256)
end

function M.packU16(value)
    return string.char(math.floor(value / 256) % 256, value % 256)
end

function M.packU32(value)
    value = value % 4294967296
    return string.char(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256
    )
end

-- Unpacking
-- Each returns (value, nextPos) or (nil, "short buffer")

function M.readU8(data, pos)
    pos = pos or 1
    if #data < pos then
        return nil, "short buffer"
    end
    return data:byte(pos), pos + 1
end

function M.readU16(data, pos)
    pos = pos or 1
    if #data < pos + 1 then
        return nil, "short buffer"
    end
    local b1, b2 = data:byte(pos, pos + 1)
    return b1 * 256 + b2, pos + 2
end

function M.readU32(data, pos)
    pos = pos or 1
    if #data < pos + 3 then
        return nil, "short buffer"
    end
    local b1, b2, b3, b4 = data:byte(pos, pos + 3)
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4, pos + 4
end

function M.readBytes(data, pos, count)
    pos = pos or 1
    if count == nil then
        return data:sub(pos)
    end
    if #data < pos + count - 1 then
        return nil, "short buffer"
    end
    return data:sub(pos, pos + count - 1), pos + count
end

-- Checksum
function M.checksum(data)
    local sum = 0
    local count = #data
    local i = 1

    while count > 1 do
        sum = sum + data:byte(i) * 256 + data:byte(i + 1)
        i = i + 2
        count = count - 2
    end

    -- left-over
    if count > 0 then
        sum = sum + data:byte(i) * 256
    end

    -- make 32-bit sum to 16 bits
    while sum > 65535 do
        sum = sum % 65536 + math.floor(sum / 65536)
    end

    return 65535 - sum
end

-- I wish I had bit32. Why removed in lua 5.4...
-- This maybe works?

local MASK32 = 0xFFFFFFFF

function M.band32(a, b)
    return ((a | 0) & (b | 0)) & MASK32
end

function M.bor32(a, b)
    return ((a | 0) | (b | 0)) & MASK32
end

function M.not32(a)
    return (~(a | 0)) & MASK32
end

function M.band32any(a, mask)
    return M.band32(a, mask) ~= 0
end

return M