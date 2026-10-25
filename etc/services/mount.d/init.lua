-- /etc/services/privileged/mount.d/init.lua
local event = require("event")
local filesystem = require("filesystem")
local process = polaris.process
local svc = {}

local listeners = {}

local rootfs = computer.getBootAddress()
local tmpfs = computer.tmpAddress()

local function onAdded(_, address, ctype)
    if address == rootfs or address == tmpfs then
        --polaris.log("Existing mount detected, ignoring: " .. tostring(address))
        return
    else
        polaris.log(tostring(ctype) .. " added: " .. tostring(address))
        local path = "/mnt/" .. address:sub(1, 3)
        filesystem.mount(address, path)
    end
end

local function onRemoved(_, address, ctype)
    if address == rootfs or address == tmpfs then
        polaris.log("Existing FS unmounted pre-shutdown! This should not happen: " .. tostring(address))
    else
        polaris.log(tostring(ctype) .. " removed: " .. tostring(address))
        filesystem.umount(address)
    end
end

function svc.start(name)
    listeners["filesystem_added"] = onAdded
    event.listen("filesystem_added", onAdded)

    listeners["filesystem_removed"] = onRemoved
    event.listen("filesystem_removed", onRemoved)

    -- Bind mount rootfs over
    -- if this fails we got issues
    local path = "/mnt/" .. rootfs:sub(1, 3)

    local rootProxy, err = filesystem.internal.proxy("/", { bind = true})
    if not rootProxy then
        process.write("mountd: bind proxy failure: " .. tostring(err) .. "\n")
        return false
    end

    local ok, err = filesystem.mount(rootProxy, path)
    if not ok then
        process.write("mountd: rootfs bind mount failure: " .. tostring(err) .. "\n")
        return false
    end

    process.write(name, ": started, listening for filesystem components\n")
    local input 
    input = process.waitForInput()
    if input == nil then input = "stopped" end
    process.write(name, ": exited: " .. tostring(input) .. "\n")

    return true
end

function svc.stop(name)
    for evname, fn in pairs(listeners) do
        event.ignore(evname, fn)
    end

    return true
end

function svc.handlers(...)
    local output = ""
    for evname, fn in pairs(listeners) do
        output = output  .. "\n" .. tostring(evname) .. " ; " .. tostring(fn)
    end

    return output
end

return svc