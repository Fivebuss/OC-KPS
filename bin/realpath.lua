-- /bin/realpath.lua
-- So simple
for _, a in ipairs(args or {}) do
    if a == "--help" then
        io.writeln("Usage: realpath [--] PATH...")
        io.writeln("Parses a path string such as . or a variable to the real canonical path")
        os.exit(0)
    end
end

-- Whoops I didnt know realpath supported multiple strings
local stopOptions = false
local targets = {}
for _, arg in ipairs(args) do
    if not stopOptions and arg == "--" then
        stopOptions = true
    else
        table.insert(targets, arg)
    end
end

if #targets == 0 then
    io.writelnError("realpath: missing operand")
    os.exit(1)
end

for _, target in ipairs(targets) do
    io.write(console.resolvePath(console.currPath(), console.stripQuotes(target)) .. "\n")
end