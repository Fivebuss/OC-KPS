-- /bin/cp.lua
local filesystem = require("filesystem")
local getopt = require("ksh.getopt")

local interactive = false
local recursive = false
local force = false
local args = { ... }

-- You get -i as usual, -R and -f to go through. Be happy
for opt, val in getopt(args, "iRrf", {}) do
    if opt == "i" then
        interactive = true
    elseif opt == "R" or opt == "r" then
        recursive = true
    elseif opt == "f" then
        force = true
    elseif opt == "?" then
        io.writelnError("cp: unrecognized option '" .. tostring(val) .. "'")
        os.exit(1)
        return
    end
end

if #args < 2 then
    io.writelnError("cp: missing operand")
    os.exit(1)
    return
end

local sources = {}
for i = 1, #args - 1 do
    table.insert(sources, console.resolvePath(console.currPath(), console.stripQuotes(args[i])))
end
local target = console.resolvePath(console.currPath(), console.stripQuotes(args[#args]))

local targetExists = filesystem.exists(target)
local targetIsDir = targetExists and filesystem.isDirectory(target)

if #sources > 1 and not targetIsDir then
    io.writelnError("cp: target '" .. args[#args] .. "' is not a directory")
    os.exit(1)
    return
end

-- Apparently it doesnt support this...
local function copyRecursive(src, dst)
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
            local ok, reason = copyRecursive(srcEntry, dstEntry)
            if not ok then
                return nil, reason
            end
        end
        return true
    else
        local shouldCopy = true
        if filesystem.exists(dst) then
            if interactive and not force then
                io.write("cp: overwrite '" .. dst .. "'? ")
                local response = io.read()
                shouldCopy = response and (response:lower() == "y" or response:lower() == "yes")
            elseif not force then
                shouldCopy = false
            end
        end

        if shouldCopy then
            return filesystem.copy(src, dst)
        end
        return true
    end
end

-- Do it
for _, source in ipairs(sources) do
    if not filesystem.exists(source) then
        io.writelnError("cp: cannot stat '" .. source .. "': no such file or directory")
    else
        local dest
        if targetIsDir then
            dest = filesystem.concat(target, filesystem.name(source))
        else
            dest = target
        end

        if filesystem.isDirectory(source) and not recursive then
            io.writelnError("cp: -r not specified; omitting directory '" .. source .. "'")
        else
            local ok, reason = copyRecursive(source, dest)
            if not ok then
                io.writelnError("cp: failed to copy '" .. source .. "' to '" .. dest .. "': " .. tostring(reason))
            end
        end
    end
    coroutine.yield()
end
