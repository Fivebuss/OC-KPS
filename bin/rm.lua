-- /bin/rm.lua
-- Scary but I need it
-- Thankfully filesystem library is alot better making this smaller

local filesystem     = require("filesystem")

local force          = false
local recursive      = false
local noPreserveRoot = false
local ignoreOptions  = false
local targets        = {}

for _, a in ipairs(args or {}) do
    if not ignoreOptions and a == "--" then
        ignoreOptions = true
    elseif not ignoreOptions and a == "-f" then
        force = true
    elseif not ignoreOptions and (a == "-r" or a == "-R" or a == "--recursive") then
        recursive = true
    elseif not ignoreOptions and (a == "-rf" or a == "-fr") then
        force = true; recursive = true
    elseif not ignoreOptions and a == "--no-preserve-root" then
        noPreserveRoot = true
    elseif not ignoreOptions and a:sub(1, 1) == "-" then
        io.writelnError("rm: invalid option: " .. a)
        io.writelnError("usage: rm [-f] [-r] [--no-preserve-root] <file...>")
        return
    else
        table.insert(targets, console.stripQuotes(a))
    end
end

if #targets == 0 then
    io.writelnError("rm: missing operand")
    io.writelnError("usage: rm [-f] [-r] [--no-preserve-root] <file...>")
    return
end

-- Anything inside and itself
local FORCE_PREFIXES = { "/dev", "/boot", "/sys" }
-- Just the location
local FORCE_EXACT    = { "/tmp" }

local function needsForce(path)
    for _, p in ipairs(FORCE_EXACT) do
        if path == p then return true end
    end
    for _, p in ipairs(FORCE_PREFIXES) do
        if path == p or path:sub(1, #p + 1) == p .. "/" then return true end
    end
    return false
end

local DRY_RUN = false

for _, rawTarget in ipairs(targets) do
    local full = filesystem.canonical(console.resolvePath(console.currPath(), rawTarget))

    if full == "/" then
        if not noPreserveRoot then
            io.writelnError("rm: refusing to remove '/': use --no-preserve-root")
            return
        end
    end

    if not filesystem.exists(full) then
        if not force then
            io.writelnError("rm: cannot remove '" .. rawTarget .. "': no such file or directory")
        end
    elseif filesystem.isDirectory(full) and not recursive then
        io.writelnError("rm: cannot remove '" .. rawTarget .. "': is a directory (use -r)")
    elseif needsForce(full) and not force then
        io.writelnError("rm: refusing to remove protected path '" .. rawTarget .. "': use -f to force removal")
    else
        if DRY_RUN then
            io.writeln("[dryrun] filesystem.remove(" .. full .. ")")
        else
            local ok, reason = filesystem.remove(full)
            if not ok then
                io.writelnError("rm: cannot remove '" .. rawTarget .. "': " .. tostring(reason))
            end
        end
    end
end
