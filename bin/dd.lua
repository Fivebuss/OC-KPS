---@diagnostic disable: cast-local-type
-- /bin/dd.lua
-- For once it exists. If only the FS didnt support only r/w/a...

local filesystem = require("filesystem")

-- AI made this bigass table
local SUFFIXES = {
    c = 1,
    w = 2,
    b = 512,
    kB = 1000,
    K = 1024,
    KiB = 1024,
    MB = 1000 * 1000,
    M = 1024 * 1024,
    MiB = 1024 * 1024,
    xM = 1024 * 1024,
    GB = 1000 ^ 3,
    G = 1024 ^ 3,
    GiB = 1024 ^ 3,
    TB = 1000 ^ 4,
    T = 1024 ^ 4,
    TiB = 1024 ^ 4,
    PB = 1000 ^ 5,
    P = 1024 ^ 5,
    PiB = 1024 ^ 5,
    EB = 1000 ^ 6,
    E = 1024 ^ 6,
    EiB = 1024 ^ 6,
    ZB = 1000 ^ 7,
    Z = 1024 ^ 7,
    ZiB = 1024 ^ 7,
    YB = 1000 ^ 8,
    Y = 1024 ^ 8,
    YiB = 1024 ^ 8,
    RB = 1000 ^ 9,
    R = 1024 ^ 9,
    RiB = 1024 ^ 9,
    QB = 1000 ^ 10,
    Q = 1024 ^ 10,
    QiB = 1024 ^ 10,
}

local function parseSize(s)
    if not s then return nil end
    local numStr, suffix = s:match("^(%d+)(.*)$")

    if not numStr then return nil end
    local num = tonumber(numStr)
    local mult = SUFFIXES[suffix]

    if mult == nil and #suffix == 2 and suffix:sub(2, 2) == "B" then
        mult = SUFFIXES[suffix:sub(1, 1)]
    end
    mult = mult or 1
    return num * mult
end

local function hasFlag(flags, name)
    if not flags or flags == "" then return false end

    for f in flags:gmatch("[^,]+") do
        if f == name then return true end
    end
    return false
end

-- Parse key=value arguments
local opts = {}
for _, arg in ipairs(args) do
    local k, v = arg:match("^([^=]+)=(.*)$")

    if k then
        opts[k] = v
    else
        io.writelnError("dd: invalid argument: " .. arg)
        os.exit(1)
    end
end

-- Limited I know
local bs = 512
local ibs = 512
local obs = 512
local count = nil
local skip = 0
local seek = 0
local status = opts.status or "none"
local ifile = opts["if"]
local ofile = opts["of"]
local iflag = opts.iflag or ""
local oflag = opts.oflag or ""

-- this is some bs
if opts.bs then
    bs = parseSize(opts.bs)
    ibs = bs
    obs = bs
end
if opts.ibs then ibs = parseSize(opts.ibs) end
if opts.obs then obs = parseSize(opts.obs) end

if opts.count then count = parseSize(opts.count) end
if opts.skip or opts.iseek then
    skip = parseSize(opts.skip or opts.iseek)
end
if opts.seek or opts.oseek then
    seek = parseSize(opts.seek or opts.oseek)
end

local useDirect = hasFlag(iflag, "direct") or hasFlag(oflag, "direct")
local useAppend = hasFlag(oflag, "append")

local function resolvePath(p)
    if not p then return p end
    p = console.stripQuotes(p)
    return console.resolvePath(console.currPath(), p)
end

if ifile then ifile = resolvePath(ifile) end
if ofile then ofile = resolvePath(ofile) end

-- Hey, you good?
if status ~= "none" and status ~= "noxfer" and status ~= "progress" then
    io.writelnError("dd: invalid status level: " .. status)
    os.exit(1)
end

-- Direct mode really just for speed
if useDirect and not ifile then
    io.writelnError("dd: direct mode requires if=FILE")
    os.exit(1)
end
if useDirect and not ofile then
    io.writelnError("dd: direct mode requires of=FILE")
    os.exit(1)
end

-- Open input
local inHandle, inIsFile, inReason
if ifile then
    local mode = "rb"
    if useDirect then
        inHandle, inReason = filesystem.open(ifile, mode)
    else
        inHandle, inReason = io.open(ifile, mode)
    end
    if not inHandle then
        io.writelnError("dd: " .. ifile .. ": " .. tostring(inReason))
        os.exit(1)
    end
    inIsFile = true
else
    inHandle = io.stdin
    inIsFile = false
end

-- Go forward
if skip > 0 and inIsFile then
    local ok, err = inHandle:seek("set", skip * ibs)
    if not ok then
        io.writelnError("dd: skip error: " .. tostring(err))
        inHandle:close()
        os.exit(1)
    end
end

-- Open output
local outHandle, outIsFile, outReason
if ofile then
    local mode = useAppend and "ab" or "wb"
    if useDirect then
        outHandle, outReason = filesystem.open(ofile, mode)
    else
        outHandle, outReason = io.open(ofile, mode)
    end
    if not outHandle then
        io.writelnError("dd: " .. ofile .. ": " .. tostring(outReason))
        if inIsFile then inHandle:close() end
        os.exit(1)
    end
    outIsFile = true
else
    outHandle = io.stdout
    outIsFile = false
end

-- Go back
if seek > 0 and outIsFile then
    local ok, err = outHandle:seek("set", seek * obs)
    if not ok then
        io.writelnError("dd: seek error: " .. tostring(err))
        if inIsFile then inHandle:close() end
        if outIsFile then outHandle:close() end
        os.exit(1)
    end
end

-- The main thing
local blocksRead = 0
local blocksWritten = 0
local bytesTotal = 0

while true do
    if count and blocksRead >= count then break end

    local block = inHandle:read(ibs)

    if not block then break end
    blocksRead = blocksRead + 1
    bytesTotal = bytesTotal + #block

    local ok, reason = outHandle:write(block)
    if not ok then
        io.writelnError("dd: write error: " .. tostring(reason))
        if inIsFile then inHandle:close() end
        if outIsFile then outHandle:close() end
        os.exit(1)
    end
    blocksWritten = blocksWritten + 1
end

if inIsFile then inHandle:close() end
if outIsFile then outHandle:close() end

-- Hey! it worked!
if status == "progress" then
    io.writelnError("dd: " .. blocksRead .. " blocks read, " ..
        blocksWritten .. " blocks written, " .. bytesTotal .. " bytes")
end

os.exit(0)
