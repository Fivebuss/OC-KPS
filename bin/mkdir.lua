-- /bin/mkdir.lua
local filesystem = require("filesystem")

local args = { ... }
local paths = {}
local verbose = false

-- -v
for _, arg in ipairs(args) do
    if arg:sub(1, 1) == "-" then
        for i = 2, #arg do
            local char = arg:sub(i, i)
            if char == "v" then
                verbose = true
            else
                io.writelnError("mkdir: invalid option -- '" .. char .. "'")
                io.writelnError("Usage: mkdir [-v] <path>...")
                os.exit(1)
            end
        end
    else
        table.insert(paths, arg)
    end
end

if #paths == 0 then
    io.writelnError("mkdir: missing operand")
    io.writelnError("Usage: mkdir [-v] <path>...")
    os.exit(1)
end

for _, rawTarget in ipairs(paths) do
    local full = filesystem.canonical(
        console.resolvePath(console.currPath(), rawTarget)
    )

    local ok, err = filesystem.makeDirectory(full)

    if not ok then
        io.writelnError(
            "mkdir: cannot create directory '" ..
            rawTarget .. "': " .. tostring(err)
        )
        os.exit(1)
    end

    if verbose then
        io.write(string.format(
            "mkdir: created directory '%s'\n", full
        ))
    end
end

os.exit(0)