-- /bin/touch.lua
local filesystem = require("filesystem")

local files = {}

for _, a in ipairs(args) do
    if a == "--help" then
        io.writeln("Usage: touch FILE...")
        io.writeln("Creates an empty file or updates modified timestamp of FILE(s)")
        os.exit(0)
    end
end

for _, arg in ipairs(args) do
    if arg:sub(1, 1) == "-" and #arg > 1 then
        io.writelnError("touch: invalid option -- '" .. arg:sub(2, 2) .. "'")
        io.writelnError("Usage: touch FILE...")
        os.exit(1)
    else
        table.insert(files, arg)
    end
end

if #files == 0 then
    io.writelnError("touch: missing file operand")
    io.writelnError("Usage: touch FILE...")
    os.exit(1)
end

local hasError = false

for _, rawTarget in ipairs(files) do
    local target = console.stripQuotes(rawTarget)
    local full = filesystem.canonical(
        console.resolvePath(console.currPath(), target)
    )

    -- Can I cheat and just do this for both cases lol
    local ok, reason = io.open(full, "wb")

    if not ok then
        io.writelnError(
            "touch: cannot touch '" ..
            rawTarget .. "': " .. tostring(reason)
        )
        hasError = true
    else
        ok:close()
    end
end

if hasError then
    os.exit(1)
end

os.exit(0)
