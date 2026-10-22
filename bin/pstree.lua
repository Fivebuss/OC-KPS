-- /bin/pstree.lua
-- Oooo fancy
-- half of this isnt my work and was given to me

local getopt = require("ksh.getopt")
local process = polaris.process

local GROUP_NAMES = {}
for name, gid in pairs(process.GID) do
    if type(gid) == "number" then
        GROUP_NAMES[gid] = name
    end
end

local function groupName(gid)
    return GROUP_NAMES[gid] or tostring(gid)
end

local function statusChar(info)
    if info.stopped then return "T" end
    if info.cancelled then return "C" end
    if info.sleeping then return "S" end
    if info.waiting then return "W" end
    if info.status == "running" then return "R" end
    if info.status == "normal" then return "N" end
    if info.status == "dead" then return "Z" end
    return "I"
end

local function fmtSeconds(n)
    n = n or 0
    return string.format("%.2f", n)
end

local function fmtIo(pid)
    local desc = process.describe(pid)
    if not desc then
        return "-"
    end

    local labels = {}
    for fd = 0, 2 do
        local d = desc[fd]
        if not d or not d.present then
            labels[#labels + 1] = fd .. ":none"
        else
            labels[#labels + 1] = fd .. ":" .. d.kind
        end
    end

    return table.concat(labels, " ")
end

local all = false
local showIo = false
local ascii = false
local verbose = false

local shortSpec = "aitV"
local longSpec = { all = "a", io = "i", ascii = "t", verbose = "verbose" }
longSpec.verbose = "V"

for opt, val in getopt(args, shortSpec, longSpec) do
    if opt == "a" then
        all = true
    elseif opt == "i" then
        showIo = true
    elseif opt == "t" then
        ascii = true
    elseif opt == "V" then
        verbose = true
    elseif opt == "?" then
        io.writelnError("pstree: unrecognized option '" .. tostring(val) .. "'")
    elseif opt == ":" then
        io.writelnError("pstree: option '" .. tostring(val) .. "' requires a value")
    end

    if verbose and opt ~= nil then
        io.writeln("pstree: parsed option '" .. tostring(opt) .. "'" .. (val and (" = " .. tostring(val)) or ""))
    end
end

local BRANCH, LAST, PIPE, SPACE
if ascii then
    BRANCH, LAST, PIPE, SPACE = "|- ", "`- ", "|  ", "   "
else
    BRANCH, LAST, PIPE, SPACE = "├─ ", "└─ ", "│  ", "   "
end

local entries = process.list()
table.sort(entries, function(a, b) return a.pid < b.pid end)

local byPid = {}
for _, e in ipairs(entries) do
    byPid[e.pid] = e
end

-- Why a process would have more than grandchildren I do not know
local children = {}
local roots = {}
for _, e in ipairs(entries) do
    local parent = e.ppid and byPid[e.ppid]
    if parent and parent.pid ~= e.pid then
        local kids = children[e.ppid]
        if not kids then
            kids = {}
            children[e.ppid] = kids
        end
        kids[#kids + 1] = e
    else
        roots[#roots + 1] = e
    end
end

for _, kids in pairs(children) do
    table.sort(kids, function(a, b) return a.pid < b.pid end)
end

local function nameOf(e)
    local base = e.cmd or e.label or "?"
    local parts = { base .. "(" .. tostring(e.pid) .. ")" }
    if e.label and e.label ~= base then
        parts[#parts + 1] = " [" .. e.label .. "]"
    end
    return table.concat(parts)
end

local function metaOf(e)
    local bits = { statusChar(e) }
    if all then
        bits[#bits + 1] = "ppid=" .. tostring(e.ppid or "-")
        bits[#bits + 1] = "age=" .. fmtSeconds(e.age)
        bits[#bits + 1] = "spawned=" .. fmtSeconds(e.spawnedAt)
        bits[#bits + 1] = "group=" .. groupName(e.gid)
    end
    if showIo then
        bits[#bits + 1] = "io=" .. fmtIo(e.pid)
    end
    return " {" .. table.concat(bits, " ") .. "}"
end

local out = {}

local function emit(e, prefix, isLast)
    local branch = isLast and LAST or BRANCH
    out[#out + 1] = prefix .. branch .. nameOf(e) .. metaOf(e)

    local kids = children[e.pid] or {}
    local kidPrefix = prefix .. (isLast and SPACE or PIPE)
    for i, kid in ipairs(kids) do
        emit(kid, kidPrefix, i == #kids)
    end
end

for i, root in ipairs(roots) do
    out[#out + 1] = nameOf(root) .. metaOf(root)
    local kids = children[root.pid] or {}
    for j, kid in ipairs(kids) do
        emit(kid, "", j == #kids)
    end
end

for i = 1, #out do
    io.writeln(out[i])
end