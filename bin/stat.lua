-- /bin/stat.lua
-- Fine il do it

local filesystem = require("filesystem")
local getopt     = require("ksh.getopt")

local terse      = false
local fsMode     = false
local followLink = false

local opts       = "tfL"
local longopts   = {
    ["terse"]       = "t",
    ["file-system"] = "f",
    ["dereference"] = "L", -- aka follow symlinks
}

for opt, val in getopt(args or {}, opts, longopts) do
    if opt == "t" then
        terse = true
    elseif opt == "f" then
        fsMode = true
    elseif opt == "L" then
        followLink = true
    elseif opt == "?" then
        io.writelnError("stat: invalid option -- '" .. val .. "'")
        os.exit(1)
        return
    end
end

if #args == 0 then
    io.writelnError("stat: missing operand")
    os.exit(1)
    return
end

local function proxyCall(fs, method)
    if not fs[method] then return nil end
    local ok, result = pcall(fs[method])
    return ok and result or nil
end

local function formatTime(ms)
    if not ms or ms == 0 then return "unknown" end
    -- lastModified is miliseconds I think?
    local s = math.floor(ms / 1000)
    local date = os.date("*t", s)
    if not date then return tostring(s) end
    return string.format("%04d-%02d-%02d %02d:%02d:%02d",
        date.year, date.month, date.day,
        date.hour, date.min, date.sec)
end

local function fileType(fullPath)
    local isLink, target = filesystem.isLink(fullPath)
    if isLink then
        return "symlink", target
    elseif filesystem.isDirectory(fullPath) then
        return "directory", nil
    else
        return "file", nil
    end
end

local function statFile(targetStr)
    local fullPath = console.resolvePath(console.currPath(), targetStr)

    if not filesystem.exists(fullPath) then
        io.writelnError("stat: cannot stat '" .. targetStr .. "': No such file or directory")
        return false
    end

    -- -L symlink
    local statPath = fullPath
    if followLink then
        local real, reason = filesystem.realPath(fullPath)
        if not real then
            io.writelnError("stat: cannot follow '" .. targetStr .. "': " .. tostring(reason))
            return false
        end
        statPath = real
        if not filesystem.exists(statPath) then
            io.writelnError("stat: cannot stat '" .. targetStr .. "': Stale symlink")
            return false
        end
    end

    if fsMode then
        -- FS info
        local proxy, mountPath = filesystem.get(statPath)
        if not proxy then
            io.writelnError("stat: cannot stat filesystem for '" .. targetStr .. "'")
            return false
        end

        local lbl = proxyCall(proxy, "getLabel")
        if not lbl or lbl == "" then lbl = tostring(proxy.address or "?") end
        local addr  = tostring(proxy.address or "?")
        local used  = proxyCall(proxy, "spaceUsed") or 0
        local total = proxyCall(proxy, "spaceTotal") or 0
        local free  = total == math.huge and "unlimited" or tostring(total - used)
        if total == math.huge then total = "unlimited" end

        if terse then
            io.writeln(table.concat({
                targetStr,
                lbl,
                addr,
                mountPath,
                tostring(used),
                tostring(total),
                free,
            }, " "))
        else
            io.writeln("  File: " .. targetStr)
            io.writeln("    ID: " .. addr)
            io.writeln(" Label: " .. lbl)
            io.writeln(" Mount: " .. mountPath)
            io.writeln("  Used: " .. tostring(used))
            io.writeln(" Total: " .. tostring(total))
            io.writeln("  Free: " .. free)
        end
    else
        -- file
        local kind, linkTarget = fileType(statPath)
        if not followLink then
            kind, linkTarget = fileType(fullPath)
        end

        local size    = filesystem.size(statPath)
        local mtime   = filesystem.lastModified(statPath)
        local real, _ = filesystem.realPath(statPath)
        real          = real or statPath

        if terse then
            local fields = {
                targetStr,
                tostring(size),
                kind,
                formatTime(mtime),
                real,
            }
            if linkTarget then
                fields[#fields + 1] = linkTarget
            end
            io.writeln(table.concat(fields, " "))
        else
            io.writeln("  File: " .. targetStr)
            if linkTarget then
                io.writeln("  Link: -> " .. linkTarget)
            end
            io.writeln("  Type: " .. kind)
            io.writeln("  Size: " .. tostring(size))
            io.writeln("Modify: " .. formatTime(mtime))
            io.writeln("  Real: " .. real)
        end
    end

    return true
end

local first = true
local anyFailed = false

for _, rawArg in ipairs(args) do
    local targetStr = console.stripQuotes(rawArg)
    if not first then
        io.writeln("")
    end
    first = false
    if not statFile(targetStr) then
        anyFailed = true
    end
end

if anyFailed then
    os.exit(1)
    return
end
