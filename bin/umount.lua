-- /bin/umount.lua
local component = require("component")
local filesystem = require("filesystem")

local args = { ... }

for _, a in ipairs(args) do
    if a == "--help" then
        io.writeln("Usage: umount PATH/ADDRESS")
        io.writeln("Unmounts PATH or component ADDRESS")
        os.exit(0)
    end
end

if #args ~= 1 then
    io.writelnError("umount: invalid arguments")
    io.writelnError("Usage: umount PATH/ADDRESS")
    os.exit(1)
end

local arg = args[1]

if type(arg) ~= "string" then
    io.writelnError("umount: argument must be a string")
    os.exit(1)
end

if arg:match(
        "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
    ) then
    if component.type(arg) ~= "filesystem" then
        io.writelnError("umount: component address is not a filesystem")
        os.exit(1)
    end
elseif not arg:match("^/.*$") then
    io.writelnError("umount: mount point must be an absolute path or filesystem address")
    os.exit(1)
end

-- unmount with address or path
local ok, err = filesystem.umount(arg)

if not ok then
    if err == nil then
        io.writelnError("umount: failed to unmount (Does the mount point exist?)")
    else
        io.writelnError("umount: filesystem error: " .. tostring(err))
    end
    os.exit(1)
end

os.exit(0)
