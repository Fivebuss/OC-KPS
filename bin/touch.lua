-- /bin/touch.lua
local filesystem = require("filesystem")

local files = {}

for _, arg in ipairs(args) do
    if arg:sub(1, 1) == "-" and #arg > 1 then
        io.writelnError("touch: invalid option -- '" .. arg:sub(2, 2) .. "'")
        io.writelnError("Usage: touch <path>...")
        os.exit(1)
        return false
    else
        table.insert(files, arg)
    end
end

if #files == 0 then
    io.writelnError("touch: missing file operand")
    io.writelnError("Usage: touch <path>...")
    os.exit(1)
    return false
end

local hasError = false

for _, rawTarget in ipairs(files) do
    local target = console.stripQuotes(rawTarget)
    local full = filesystem.canonical(
        console.resolvePath(console.currPath(), target)
    )

    -- Can I cheat and just do this for both cases lol
    local ok, reason = filesystem.open(full, "wb")

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
    return false
end

os.exit(0)
