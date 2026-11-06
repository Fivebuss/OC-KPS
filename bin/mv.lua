-- /bin/mv.lua
-- Just a copy of cp.lua
local filesystem = require("filesystem")
local getopt = require("ksh.getopt")

local interactive = false
local args = { ... }

-- who else uses the others
for opt, val in getopt(args, "i", {}) do
    if opt == "i" then
        interactive = true
    elseif opt == "?" then
        io.writelnError("mv: unrecognized option '" .. tostring(val) .. "'")
        os.exit(1)
    end
end

if #args < 2 then
    io.writelnError("mv: missing operand")
    os.exit(1)
end

local sources = {}
for i = 1, #args - 1 do
    table.insert(sources, console.resolvePath(console.currPath(), console.stripQuotes(args[i])))
end
local target = console.resolvePath(console.currPath(), console.stripQuotes(args[#args]))

local targetExists = filesystem.exists(target)
local targetIsDir = targetExists and filesystem.isDirectory(target)

if #sources > 1 and not targetIsDir then
    io.writelnError("mv: target '" .. args[#args] .. "' is not a directory")
    os.exit(1)
end

if #sources > 1 and not targetExists then
    io.writelnError("mv: target '" .. args[#args] .. "' does not exist")
    os.exit(1)
end

-- Apparently it doesnt support this...
local function moveRecursive(src, dst)
    if filesystem.isDirectory(src) then
        if not filesystem.exists(dst) then
            local ok, reason = filesystem.makeDirectory(dst)
            if not ok then
                return nil, reason
            end
        elseif not filesystem.isDirectory(dst) then
            return nil, "cannot overwrite non-directory with directory"
        end

        for entry in filesystem.list(src) do
            local srcEntry = filesystem.concat(src, entry)
            local dstEntry = filesystem.concat(dst, entry)
            local ok, reason = moveRecursive(srcEntry, dstEntry)
            if not ok then
                return nil, reason
            end
        end
        return filesystem.remove(src)
    else
        local shouldMove = true
        if filesystem.exists(dst) then
            if interactive then
                io.write("mv: overwrite '" .. dst .. "'? ")
                local response = io.read()
                shouldMove = response and (response:lower() == "y" or response:lower() == "yes")
            else
                shouldMove = false
            end
        end

        if shouldMove then
            local ok, reason = filesystem.copy(src, dst)
            if ok then
                return filesystem.remove(src)
            else
                return nil, reason
            end
        end
        return true
    end
end

-- Do it
for _, source in ipairs(sources) do
    if not filesystem.exists(source) then
        io.writelnError("mv: cannot stat '" .. source .. "': no such file or directory")
    else
        local dest
        if targetIsDir then
            dest = filesystem.concat(target, filesystem.name(source))
        else
            dest = target
        end

        local ok, reason = moveRecursive(source, dest)
        if not ok then
            io.writelnError("mv: failed to move '" .. source .. "' to '" .. dest .. "': " .. tostring(reason))
        end
    end

    if coroutine.yield() == "INT" then
        os.exit(130)
    end
end
