-- /bin/mount.lua
local component = require("component")
local event = require("event")
local filesystem = require("filesystem")
local process = require("process")

local args = { ... }

if #args == 2 then
    local address = args[1]
    local path = args[2]

    -- Check if its a valid address
    if type(address) ~= "string"
        or not address:match(
            "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
        ) then
        io.writelnError("mount: invalid filesystem address")
        os.exit(1)
    end

    if component.type(address) ~= "filesystem" then
        io.writelnError("mount: component address is not a filesystem")
        os.exit(1)
    end

    if type(path) ~= "string"
        or not path:match("^/.*$") then
        io.writelnError("mount: mount point must be an absolute path")
        os.exit(1)
    end

    local ok, err = filesystem.mount(address, path)

    if not ok then
        io.writelnError("mount: filesystem error: " .. tostring(err))
        os.exit(1)
    end
elseif #args == 3 and args[1] == "-b" then
    local source_path = args[2]
    local target_path = args[3]

    if type(source_path) ~= "string" or not source_path:match("^/.*$") then
        io.writelnError("mount: source path must be an absolute path")
        os.exit(1)
    end

    if type(target_path) ~= "string" or not target_path:match("^/.*$") then
        io.writelnError("mount: target path must be an absolute path")
        os.exit(1)
    end

    -- Bind mount
    local proxy, err = filesystem.internal.proxy(source_path, { bind = true })
    if not proxy then
        io.writelnError("mount: failed to create bind proxy: " .. tostring(err))
        os.exit(1)
    end

    local ok, mount_err = filesystem.mount(proxy, target_path)
    if not ok then
        io.writelnError("mount: filesystem error: " .. tostring(mount_err))
        os.exit(1)
    end
else
    io.writelnError("mount: invalid arguments")
    io.writelnError("Usage: mount [-b] (path or address) (target path)")
    os.exit(1)
end

os.exit(0)
