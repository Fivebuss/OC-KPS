-- /bin/ls.lua
-- This got big quickly

local filesystem = require("filesystem")
local getopt = require("ksh.getopt")

local showAll = false
local listDirSelf = false
local commaSeparated = false
local reverseOrder = false
local recursive = false
local rowMajor = false
local singleColumn = false

-- Il support just some basic stuff to justify getopt existing
local opts = "madrRx1"
local longopts = {
    all = "a",
    directory = "d",
    recursive = "R",
}

for opt, val in getopt(args or {}, opts, longopts) do
    if opt == "a" then
        showAll = true
    elseif opt == "d" then
        listDirSelf = true
    elseif opt == "m" then
        commaSeparated = true
    elseif opt == "r" then
        reverseOrder = true
    elseif opt == "R" then
        recursive = true
    elseif opt == "x" then
        rowMajor = true
    elseif opt == "1" then
        singleColumn = true
    elseif opt == "?" then
        io.writelnError("ls: invalid option -- '" .. val .. "'")
        os.exit(1)
        return
    end
end

-- When I get around to console driver this will go away
local termWidth = 80
if polaris and polaris.gpu and polaris.gpu.getResolution then
    termWidth = polaris.gpu.getResolution()
end

local rawTargets = args
local targets = {}

if #rawTargets == 0 then
    targets[1] = console.currPath()
else
    for _, rawTarget in ipairs(rawTargets) do
        targets[#targets + 1] = console.stripQuotes(rawTarget)
    end
end

-- Fancy
local function printFormatted(names)
    if #names == 0 then return end
    if reverseOrder then
        local rev = {}
        for i = #names, 1, -1 do rev[#rev + 1] = names[i] end
        names = rev
    end

    if singleColumn then
        for _, name in ipairs(names) do
            io.writeln(name)
        end
        return
    end

    if commaSeparated then
        local line = ""
        for i, name in ipairs(names) do
            local item = name .. (i < #names and ", " or "")
            if #line > 0 and #line + #item > termWidth then
                io.writeln(line)
                line = item
            else
                line = line .. item
            end
        end
        if #line > 0 then io.writeln(line) end
        return
    end

    local maxLen = 0
    for _, name in ipairs(names) do
        if #name > maxLen then maxLen = #name end
    end

    local colWidth = maxLen + 1
    local numCols = math.max(1, math.floor((termWidth + 1) / colWidth))
    local numRows = math.ceil(#names / numCols)

    for r = 1, numRows do
        local line = ""
        for c = 1, numCols do
            local idx = rowMajor and ((r - 1) * numCols + c) or ((c - 1) * numRows + r)
            if idx <= #names then
                local name = names[idx]
                local hasNext = rowMajor and ((c < numCols) and (idx < #names)) or
                    ((c < numCols) and (idx + numRows <= #names)) -- gross
                if hasNext then
                    line = line .. name .. string.rep(" ", maxLen - #name + 1)
                else
                    line = line .. name
                end
            end
        end
        io.writeln(line)
    end
end

local function getDirEntries(dirPath)
    local names = {}
    for name in filesystem.list(dirPath) do
        local cleanName = filesystem.canonical(name)
        if showAll or cleanName:sub(1, 1) ~= "." then
            names[#names + 1] = cleanName
        end
    end
    table.sort(names)
    return names
end

local function listDirectory(dirPath, showHeader, headerName)
    if showHeader then
        io.writeln((headerName or dirPath) .. ":")
    end

    local entries = getDirEntries(dirPath)
    printFormatted(entries)

    if recursive then
        local subdirs = {}
        for _, name in ipairs(entries) do
            if name ~= "." and name ~= ".." then
                local fullSub = filesystem.concat(dirPath, name)
                if filesystem.exists(fullSub) and filesystem.isDirectory(fullSub) then
                    subdirs[#subdirs + 1] = fullSub
                end
            end
        end
        if reverseOrder then
            local rev = {}
            for i = #subdirs, 1, -1 do rev[#rev + 1] = subdirs[i] end
            subdirs = rev
        end
        for _, sub in ipairs(subdirs) do
            io.writeln("")
            listDirectory(sub, true, sub)
        end
    end
end

local fileTargets = {}
local dirTargets = {}

-- Can we get all?
for _, targetStr in ipairs(targets) do
    local fullPath = console.resolvePath(console.currPath(), targetStr)
    if not filesystem.exists(fullPath) then
        io.writelnError("ls: cannot access '" .. targetStr .. "': No such file or directory")
        os.exit(1)
    elseif listDirSelf or not filesystem.isDirectory(fullPath) then
        fileTargets[#fileTargets + 1] = targetStr
    else
        dirTargets[#dirTargets + 1] = { raw = targetStr, full = fullPath }
    end
end

table.sort(fileTargets)
if #fileTargets > 0 then
    printFormatted(fileTargets)
end

if #fileTargets > 0 and #dirTargets > 0 then
    io.writeln("")
end

table.sort(dirTargets, function(a, b) return a.raw < b.raw end)
if reverseOrder then
    local rev = {}
    for i = #dirTargets, 1, -1 do rev[#rev + 1] = dirTargets[i] end
    dirTargets = rev
end

local multipleDirHeader = (#targets > 1 or #fileTargets > 0)
for i, dirInfo in ipairs(dirTargets) do
    if i > 1 then io.writeln("") end
    listDirectory(dirInfo.full, multipleDirHeader or recursive, dirInfo.raw)
end
