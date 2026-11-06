-- /bin/realpath.lua
-- So simple
if #args ~= 1 then
    io.writelnError("realpath: Invalid directory")
    os.exit(1)
    return
end

local target = console.resolvePath(console.currPath(), console.stripQuotes(args[1]))
io.write(target)