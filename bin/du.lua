-- /bin/du.lua

local filesystem    = require("filesystem")
local getopt        = require("ksh.getopt")

local humanReadable = false
local summarize     = false
local showHidden    = false -- -o, show hidden. Its seperate purely for me because of .git folder
local countFiles    = false -- -a
local grandTotal    = false -- -c the total only
local maxDepth      = nil   -- -d depth

local opts          = "hsoacd:"
local longopts      = {
    ["human-readable"] = "h",
    ["summarize"]      = "s",
    ["all"]            = "a",
    ["count"]          = "c",
    ["depth"]          = "d",
}

for opt, val in getopt(args or {}, opts, longopts) do
    if opt == "h" then
        humanReadable = true
    elseif opt == "s" then
        summarize = true
    elseif opt == "o" then
        showHidden = true
    elseif opt == "a" then
        countFiles = true
    elseif opt == "c" then
        grandTotal = true
    elseif opt == "d" then
        maxDepth = tonumber(val)
        if not maxDepth then
            io.writelnError("du: invalid argument to -d: '" .. tostring(val) .. "'")
            os.exit(1)
        end
    elseif opt == "?" then
        io.writelnError("du: invalid option -- '" .. val .. "'")
        os.exit(1)
    end
end

-- -s is equivalent to -d 0
if summarize then
    maxDepth = 0
end

local targets = {}

if #args == 0 then
    targets[1] = "."
else
    for _, rawArg in ipairs(args) do
        targets[#targets + 1] = console.stripQuotes(rawArg)
    end
end

local function formatSize(size)
    if not humanReadable then
        return tostring(size)
    end
    local suffixes = { "", "K", "M", "G" }
    local unit = 1
    local power = 1024
    while size > power and unit < #suffixes do
        unit = unit + 1
        size = size / power
    end
    return math.floor(size * 10) / 10 .. suffixes[unit]
end

local function printSize(size, path)
    io.writeln(string.format("%-12s%s", formatSize(size), path))
end

local function addTrailingSlash(path)
    if path:sub(-1) ~= "/" then
        return path .. "/"
    end
    return path
end

-- This may cause memory problems, I hope its fine...
local function visit(rpath, depth)
    local fullPath = console.resolvePath(console.currPath(), rpath)

    if filesystem.isDirectory(fullPath) then
        local subtotal = 0

        for entry in filesystem.list(fullPath) do
            local entryName  = entry:match("^(.-)/+$") or entry
            local isHidden   = entryName:sub(1, 1) == "."

            local childRpath = addTrailingSlash(rpath) .. entryName
            local childFull  = console.resolvePath(console.currPath(), childRpath)

            if filesystem.isDirectory(childFull) then
                local childTotal = visit(childRpath, depth + 1)
                subtotal = subtotal + childTotal
            elseif not filesystem.isLink(childFull) then
                local fileSize = filesystem.size(childFull)
                subtotal = subtotal + fileSize

                if countFiles and (showHidden or not isHidden) then
                    if maxDepth == nil or (depth + 1) <= maxDepth then
                        printSize(fileSize, childRpath)
                    end
                end
            end
            if coroutine.yield() == "INT" then
                os.exit(130)
            end
        end

        -- ./
        local dirName  = filesystem.name(rpath) or rpath
        local isHidden = dirName:sub(1, 1) == "."
        if showHidden or not isHidden or depth == 0 then
            if maxDepth == nil or depth <= maxDepth then
                printSize(subtotal, rpath)
            end
        end

        return subtotal
    elseif filesystem.isLink(fullPath) then
        return 0
    else
        return filesystem.size(fullPath)
    end
end

local combined = 0

for _, targetStr in ipairs(targets) do
    local fullPath = console.resolvePath(console.currPath(), targetStr)

    if not filesystem.exists(fullPath) then
        io.writelnError("du: cannot access '" .. targetStr .. "': No such file or directory")
        os.exit(1)
    elseif filesystem.isDirectory(fullPath) then
        local total = visit(targetStr, 0)
        combined = combined + total
    elseif filesystem.isLink(fullPath) then
        printSize(0, targetStr)
    else
        local size = filesystem.size(fullPath)
        printSize(size, targetStr)
        combined = combined + size
    end

    if coroutine.yield() == "INT" then
        os.exit(130)
    end
end

if grandTotal then
    printSize(combined, "total")
end
