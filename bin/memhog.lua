-- /bin/memhog.lua
-- lets test GC

local process = require("process")
local args = { ... }

local verbose = false
local target = nil

for i = 1, #args do
    if args[i] == "-v" then
        verbose = true
    elseif target == nil then
        target = args[i]
    else
        io.stderr:write("Usage: memhog [-v] <bytes|max> [-v]\n")
        os.exit(1)
        return
    end
end

if target == nil then
    io.stderr:write("Usage: memhog [-v] <bytes|max> [-v]\n")
    os.exit(1)
    return
end

local maxMode = target == "max"

if not maxMode then
    target = tonumber(target)

    if not target or target < 0 then
        io.stderr:write("Expected a non-negative byte count or 'max'\n")
        os.exit(1)
        return
    end

    target = math.floor(target)
end

-- I think these are right
local TABLE_OVERHEAD = 64
local ENTRY_OVERHEAD = 32
local CHUNK_SIZE = 256
local ENTRIES_PER_CHUNK = 64

-- Stay referenced!
_G.__memhog = _G.__memhog or {}
local allocations = _G.__memhog

local allocated = 0

local function allocateChunk(count)
    local t = {}

    for i = 1, count do
        t[i] = string.rep("M", CHUNK_SIZE)
    end

    return t
end

local function estimateChunk(count)
    return TABLE_OVERHEAD + count * (ENTRY_OVERHEAD + CHUNK_SIZE)
end

if not maxMode and target == 0 then
    os.exit(0)
    return
end

while maxMode or allocated < target do
    local count = ENTRIES_PER_CHUNK

    if not maxMode then
        count = math.min(
            ENTRIES_PER_CHUNK,
            math.max(1, math.ceil(
                (target - allocated) / (ENTRY_OVERHEAD + CHUNK_SIZE)
            ))
        )
    end

    local ok, result = pcall(allocateChunk, count)
    coroutine.yield()

    if not ok then
        io.stderr:write(
            "Allocation failed after ~"
            .. tostring(allocated) .. " bytes\n"
        )

        if verbose then
            io.stderr:write("Error: " .. tostring(result) .. "\n")
        end

        os.exit(0)
        return
    end

    allocations[#allocations + 1] = result
    allocated = allocated + estimateChunk(count)
end

os.exit(0)
return
