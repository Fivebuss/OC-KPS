-- /boot/boot.lua

-- Preserve
local component = component
local computer = computer
local unicode = unicode

local addr = computer.getBootAddress()
local invoke = component.invoke
_G._OSVERSION = "KPS 0.2"


-- Load and execute a Lua file.
function loadfile(path)
    local handle = assert(invoke(addr, "open", path))
    local chunks = {}
    repeat
        local data = invoke(addr, "read", handle, math.maxinteger or math.huge)
        if data then chunks[#chunks + 1] = data end
    until not data
    return assert(load(table.concat(chunks), "=" .. path, "bt", _G))
end

function dofile(path)
    return loadfile(path)()
end

-- Initialize GPU
local gpu = (function()
    local w, h
    local screen = component.list("screen", true)()
    local gpu = screen and component.list("gpu", true)()

    if gpu then
        gpu = component.proxy(gpu)

        if not gpu.getScreen() then
            gpu.bind(screen)
        end

        w, h = gpu.maxResolution()
        gpu.setResolution(w, h)
        gpu.setBackground(0x000000)
        gpu.setForeground(0xFFFFFF)
        gpu.fill(1, 1, w, h, " ")
    end

    return gpu, w, h
end)()

_G.gpu = gpu

local y = 1
local w, h = 0, 0

if gpu then
    w, h = gpu.getResolution()
end

function _G.status(msg)
    if not gpu then
        return
    end

    msg = tostring(msg)

    gpu.set(1, y, msg)

    if y == h then
        gpu.copy(1, 2, w, h - 1, 0, -1)
        gpu.fill(1, h, w, 1, " ")
    else
        y = y + 1
    end
end

status("Booting " .. _G._OSVERSION)
status("===============")

status("Initializing package management")

-- Initialize package management.
local package = dofile("/boot/modules/package.lua")

-- Remove firmware/kernel APIs from the global namespace.
_G.component = nil
_G.process = nil
_G.unicode = nil

-- Make the package manager globally available.
_G.package = package


status("Registering modules")

-- Register modules
package.loaded.component = component
package.loaded.computer = computer
package.loaded.unicode = unicode
package.loaded.filesystem = dofile("/lib/filesystem.lua")

local filesystem = require("filesystem")


status("Mounting root filesystem")

-- Mount rootfs
filesystem.mount(addr, "/")

-- Initialize kernel
status(dofile("/sys/kernel/kinit.lua"))

status("Executing stage 2 boot")

-- Now that things have been prepared

-- Lets load them all at once to save time
local bootScripts = assert(dofile("/boot/bootscripts.lua"))

if polaris.config["debug"] == true then
    _G.polaris.debug = {}
    _G.polaris.debug.print = status
end

-- So they are in order
local bootNames = {}
for name in pairs(bootScripts) do
    table.insert(bootNames, name)
end
table.sort(bootNames)
for i = 1, #bootNames do
    local name = bootNames[i]
    status("> " .. name)
    local chunk, err = load(bootScripts[name], "=" .. name, "bt", _G)
    if not chunk then
        error("failed to load stage 2 boot script '" .. name .. "': " .. tostring(err), 0)
    end
    chunk()
end

-- Enter scheduler loop
-- No matter what you do, no matter how hard you try you will always be in a busy loop lmao

local event_internals =
    require("event_internals")

while true do
    event_internals.pullSignal()
end
