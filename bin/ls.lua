-- /bin/ls.lua
-- Todo: make better
local filesystem = require("filesystem")

local target = args[2] and console.stripQuotes(args[2]) or console.currPath()
local fullPath = console.resolvePath(console.currPath(), target)

if not filesystem.exists(fullPath) then
    io.writelnError("ls: cannot access '" .. target .. "': No such file or directory")
    return
end

if not filesystem.isDirectory(fullPath) then
    io.writeln(target)
    return
end

local names = {}
for name in filesystem.list(fullPath) do
    names[#names + 1] = name
end
table.sort(names)

for _, name in ipairs(names) do
    io.writeln(name)
end