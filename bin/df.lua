-- /bin/df.lua

local filesystem = require("filesystem")
local getopt = require("ksh.getopt")

local humanReadable = false
local siUnits = false

local opts = "hi" -- hello back
local longopts = {
    ["human-readable"] = "h",
    ["si"]             = "i",
}

for opt, val in getopt(args or {}, opts, longopts) do
    if opt == "h" then
        humanReadable = true
    elseif opt == "i" then
        siUnits = true
    elseif opt == "?" then
        io.writelnError("df: invalid option -- '" .. val .. "'")
        os.exit(1)
        return
    end
end

local function formatSize(size)
    if not humanReadable then
        return tostring(size)
    elseif type(size) == "string" then
        return size
    end
    local suffixes = { "", "K", "M", "G" }
    local unit = 1
    local power = siUnits and 1000 or 1024
    while size > power and unit < #suffixes do
        unit = unit + 1
        size = size / power
    end
    return math.floor(size * 10) / 10 .. suffixes[unit]
end

local function proxyCall(fs, method)
    if not fs[method] then return nil end
    local ok, result = pcall(fs[method])
    return ok and result or nil
end

-- yeah this is weird
local mounts = {}

if #args == 0 then
    local iter = filesystem.mounts()
    while true do
        local proxy, path = iter()
        if not proxy then break end
        if not mounts[proxy] or #path < #mounts[proxy] then
            mounts[proxy] = path
        end
    end
else
    for _, rawArg in ipairs(args) do
        local targetStr   = console.stripQuotes(rawArg)
        local fullPath    = console.resolvePath(console.currPath(), targetStr)
        local proxy, path = filesystem.get(fullPath)
        if not proxy then
            io.writelnError("df: " .. targetStr .. ": no such file or directory")
            os.exit(1)
            return
        end
        if not mounts[proxy] or #path < #mounts[proxy] then
            mounts[proxy] = path
        end
    end
end

local rows = { { "Filesystem", "Used", "Available", "Use%", "Mounted on" } }

for proxy, path in pairs(mounts) do
    local lbl = proxyCall(proxy, "getLabel")
    if not lbl or lbl == "" then lbl = tostring(proxy.address or "?") end
    local used  = proxyCall(proxy, "spaceUsed") or 0
    local total = proxyCall(proxy, "spaceTotal") or 0
    local available, percent

    if total == math.huge then
        available = "unlimited"
        percent   = "0%"
    else
        available = total - used
        local ratio = used / total
        if ratio ~= ratio then -- NaN?
            available = "N/A"
            percent   = "N/A"
        else
            percent = math.ceil(ratio * 100) .. "%"
        end
    end

    rows[#rows + 1] = {
        lbl,
        formatSize(used),
        formatSize(available),
        percent,
        path,
    }
    coroutine.yield()
end

local colWidths = {}
for _, row in ipairs(rows) do
    for col, value in ipairs(row) do
        colWidths[col] = math.max(colWidths[col] or 1, #value)
    end
end

for _, row in ipairs(rows) do
    local line = ""
    for col, value in ipairs(row) do
        if col == #row then
            line = line .. value
        else
            line = line .. value .. string.rep(" ", colWidths[col] - #value + 2)
        end
    end
    io.writeln(line)
end
