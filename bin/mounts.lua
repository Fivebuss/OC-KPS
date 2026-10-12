-- /bin/mounts.lua

local filesystem = require("filesystem")

local args = { ... }

-- Im lazy
local MAX_DEPTH = 5

local mode = "mounts"

for _, arg in ipairs(args) do
    if arg == "-m" then
        mode = "mtab"
    else
        io.writelnError("mounts: unknown option: " .. arg)
        io.writelnError("Usage: mounts [-m]")
        os.exit(1)
        return
    end
end

local function label(fs)
    if not fs then
        return "?"
    end

    if fs.getLabel then
        local ok, value = pcall(fs.getLabel)
        if ok and value and value ~= "" then
            return tostring(value)
        end
    end

    return "unknown"
end

local function address(fs)
    return fs and tostring(fs.address or "?") or "?"
end

local function printMounts()
    io.writeln("Filesystem mounts:")
    io.writeln(string.format("%-28s  %-20s  %s",
        "MOUNT POINT", "LABEL", "ADDRESS"))

    local iter = filesystem.mounts()
    local mounts = {}

    while true do
        local fs, path = iter()
        if not fs then
            break
        end

        mounts[#mounts + 1] = {
            path = path,
            fs = fs,
        }
    end

    table.sort(mounts, function(a, b)
        return a.path < b.path
    end)

    for _, mount in ipairs(mounts) do
        io.writeln(string.format("%-28s  %-20s  %s",
            mount.path,
            label(mount.fs),
            address(mount.fs)))
    end
end

local function printMtab()
    io.writeln("Filesystem mtab:")

    local function treeFollow(node, depth, prefix)
        if depth > MAX_DEPTH then
            return
        end

        local name = node.name
        local displayName = name == "" and "/" or name

        if node.fs then
            displayName = displayName .. string.format(
                " [mounted: %s, %s]",
                label(node.fs),
                address(node.fs)
            )
        end

        io.writeln(prefix .. displayName)

        if depth >= MAX_DEPTH then
            return
        end

        local children = {}

        for childName, child in pairs(node.children or {}) do
            children[#children + 1] = {
                name = childName,
                node = child,
            }
        end

        table.sort(children, function(a, b)
            return a.name < b.name
        end)

        for _, child in ipairs(children) do
            treeFollow(child.node, depth + 1, prefix .. "  ")
        end

        local links = {}

        for linkName, target in pairs(node.links or {}) do
            links[#links + 1] = {
                name = linkName,
                target = target,
            }
        end

        table.sort(links, function(a, b)
            return a.name < b.name
        end)

        for _, link in ipairs(links) do
            io.writeln(prefix .. "  " .. link.name ..
                " -> " .. tostring(link.target))
        end
    end

    treeFollow(filesystem.mtab, 0, "")
end

if mode == "mounts" then
    printMounts()
elseif mode == "mtab" then
    printMtab()
end
