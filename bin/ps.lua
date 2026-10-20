-- /bin/ps.lua
-- Shares the name, not the implementation, with Linux ps :)

local getopt = require("ksh.getopt")
local process = polaris.process

-- GID names
local GID_NAMES = {}
for name, gid in pairs(process.GID) do
    if type(gid) == "number" then
        GID_NAMES[gid] = name
    end
end

local function gidName(gid)
    if gid == nil then return "-" end
    return GID_NAMES[gid] or tostring(gid)
end

-- Process status
local function statusChar(info)
    if info.protected then return "K" end
    if info.stopped then return "T" end
    if info.cancelled then return "C" end
    if info.sleeping then return "S" end
    if info.waiting then return "W" end

    if info.status == "running" then return "R" end
    if info.status == "normal" then return "N" end
    if info.status == "dead" then return "Z" end

    return "I"
end

local function fmtSeconds(n, human)
    n = n or 0

    if human then
        return string.format("%ds", math.floor(n + 0.5))
    end

    return string.format("%.2f", n)
end

local function fmtIo(pid, human)
    local desc = process.describe(pid)

    if not desc then
        return human and "-" or "-,-,-"
    end

    local labels = {}
    for fd = 0, 2 do
        local d = desc[fd]

        if not d or not d.present then
            labels[#labels + 1] = human and (fd .. ":none") or "-"
        else
            local kind = d.kind or "?"
            labels[#labels + 1] = human and (fd .. ":" .. kind) or kind
        end
    end

    return table.concat(labels, human and " " or ",")
end

local function fmtCtty(e)
    if not e.ctty then return "-" end
    return e.ctty:match("(%x%x%x%x)$") or e.ctty:sub(-4)
end

-- Options
local all = false
local human = false
local showIo = false
local verbose = false

local shortSpec = "uaxifhV"
local longSpec = {
    all = "a",
    human = "h",
    verbose = "V",
}

for opt, val in getopt(args, shortSpec, longSpec) do
    if opt == "u" then
    elseif opt == "a" then
        all = true
    elseif opt == "x" then
    elseif opt == "i" then
        showIo = true
    elseif opt == "f" then
        io.writelnError("ps: -f not implemented")
    elseif opt == "h" then
        human = true
    elseif opt == "V" then
        verbose = true
    elseif opt == "?" then
        io.writelnError("ps: unrecognized option '" .. tostring(val) .. "'")
    elseif opt == ":" then
        io.writelnError("ps: option '" .. tostring(val) .. "' requires a value")
    end

    if verbose and opt ~= nil then
        io.writeln(
            "ps: parsed option '" .. tostring(opt) .. "'" ..
            (val ~= nil and (" = " .. tostring(val)) or "")
        )
    end
end

local entries = process.list()

table.sort(entries, function(a, b)
    return a.pid < b.pid
end)

local function cmdOrLabel(e)
    if human then
        return e.label or e.cmd or "?"
    end

    return e.cmd or "?"
end

local header
local rowFn

if all then
    if human then
        header = {
            "LABEL", "PID", "PPID", "UID", "AGE",
            "SPAWNED", "S", "GROUP", "TTY",
        }

        if showIo then
            header[#header + 1] = "IO"
        end

        rowFn = function(e)
            local row = {
                cmdOrLabel(e),
                tostring(e.pid),
                tostring(e.ppid or "-"),
                tostring(e.uid or "-"),
                fmtSeconds(e.age, true),
                fmtSeconds(e.spawnedAt, true),
                statusChar(e),
                gidName(e.gid),
                fmtCtty(e),
            }

            if showIo then
                row[#row + 1] = fmtIo(e.pid, true)
            end

            return row
        end
    else
        header = {
            "CMD", "PID", "PPID", "UID", "GID", "LABEL",
            "AGE", "SPAWNED", "S", "TTY",
        }

        if showIo then
            header[#header + 1] = "IO"
        end

        rowFn = function(e)
            local row = {
                cmdOrLabel(e),
                tostring(e.pid),
                tostring(e.ppid or "-"),
                tostring(e.uid or "-"),
                tostring(e.gid or "-"),
                e.label or "-",
                fmtSeconds(e.age, false),
                fmtSeconds(e.spawnedAt, false),
                statusChar(e),
                fmtCtty(e),
            }

            if showIo then
                row[#row + 1] = fmtIo(e.pid, false)
            end

            return row
        end
    end
else
    if human then
        header = { "LABEL", "PID", "PPID", "AGE", "S", "TTY" }

        if showIo then
            header[#header + 1] = "IO"
        end

        rowFn = function(e)
            local row = {
                cmdOrLabel(e),
                tostring(e.pid),
                tostring(e.ppid or "-"),
                fmtSeconds(e.age, true),
                statusChar(e),
                fmtCtty(e),
            }

            if showIo then
                row[#row + 1] = fmtIo(e.pid, true)
            end

            return row
        end
    else
        header = {
            "CMD", "PID", "PPID", "LABEL", "AGE", "S", "TTY",
        }

        if showIo then
            header[#header + 1] = "IO"
        end

        rowFn = function(e)
            local row = {
                cmdOrLabel(e),
                tostring(e.pid),
                tostring(e.ppid or "-"),
                e.label or "-",
                fmtSeconds(e.age, false),
                statusChar(e),
                fmtCtty(e),
            }

            if showIo then
                row[#row + 1] = fmtIo(e.pid, false)
            end

            return row
        end
    end
end

local rows = {}

for _, e in ipairs(entries) do
    rows[#rows + 1] = rowFn(e)
end

local widths = {}

for i, cell in ipairs(header) do
    widths[i] = #cell
end

for _, row in ipairs(rows) do
    for i, cell in ipairs(row) do
        widths[i] = math.max(widths[i], #cell)
    end
end

local function writeRow(row)
    local pieces = {}

    for i, cell in ipairs(row) do
        pieces[#pieces + 1] =
            cell .. string.rep(" ", widths[i] - #cell)
    end

    io.writeln(table.concat(pieces, "  "))
end

writeRow(header)

for _, row in ipairs(rows) do
    writeRow(row)
end
