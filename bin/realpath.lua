-- /bin/realpath.lua
-- So simple
for _, a in ipairs(args or {}) do
    if a == "--help" then
        io.writeln("Usage: realpath PATH")
        io.writeln("Parses a path string such as . or a variable to the real canonical path")
        os.exit(0)
    end
end

if #args ~= 1 then
    io.writelnError("realpath: Invalid directory")
    os.exit(1)
end

local target = console.resolvePath(console.currPath(), console.stripQuotes(args[1]))
io.write(target)