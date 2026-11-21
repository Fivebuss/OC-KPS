-- /bin/rm.lua
-- Scary but I need it
-- Thankfully filesystem library is alot better making this smaller

local filesystem     = require("filesystem")
local getopt         = require("ksh.getopt")

local force          = false
local recursive      = false
local noPreserveRoot = false
local targets        = {}

local arglist = args or {}

for opt, val in getopt(arglist, "frRPH", { ["recursive"] = "r", ["no-preserve-root"] = "P", ["help"] = "H" }) do
    if opt == "f" then
        force = true
    elseif opt == "r" or opt == "R" then
        recursive = true
    elseif opt == "P" then
        noPreserveRoot = true
    elseif opt == "H" then
        io.writeln("Usage: rm [-f] [-r] [--no-preserve-root] FILE...")
        io.writeln("Removes FILE(s) or folders")
        io.writeln("  -f force removal")
        io.writeln("  -r, -R remove directories")
        io.writeln("  --no-preserve-root allows removing '/'")
        os.exit(0)
    elseif opt == "?" then
        io.writelnError("rm: invalid option -- '" .. tostring(val) .. "'")
        io.writelnError("usage: rm [-f] [-r] [--no-preserve-root] <file...>")
        return
    end
end

local start = 1
if arglist[1] == "--" then start = 2 end
for i = start, #arglist do
    table.insert(targets, console.stripQuotes(arglist[i]))
end

if #targets == 0 then
    io.writelnError("rm: missing operand")
    io.writelnError("usage: rm [-f] [-r] [--no-preserve-root] FILE...")
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

local DRY_RUN = true

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
