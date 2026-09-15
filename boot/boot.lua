-- /boot/boot.lua

-- Preserve
local component = component
local computer = computer
local unicode = unicode

local addr = computer.getBootAddress()
local invoke = component.invoke
_G._OSVERSION = "KPS 0.1"


-- Load and execute a Lua file.
function loadfile(path)
    local handle = assert(invoke(addr, "open", path))
    local buffer = ""
    repeat
        local data = invoke(addr, "read", handle, math.maxinteger or math.huge)
        buffer = buffer .. (data or "")
    until not data
    invoke(addr, "close", handle)
    return assert(load(buffer, "=" .. path, "bt", _G))
end

function dofile(path)
    return loadfile(path)()
end

-- Initialize GPU
local gpu = dofile("/boot/modules/gpu.lua")
_G.gpu = gpu

local y = 1
local w, h = 0, 0

if gpu then
    w, h = gpu.getResolution()
    gpu.fill(1, 1, w, h, " ")
end

local function status(msg)
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

status("GPU Initialized")
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

local bootScripts = {}
for file in filesystem.list("/boot") do
    local path = "/boot/" .. file
    if file ~= "boot.lua" and not filesystem.isDirectory(path) and file:sub(-4) == ".lua" then
        table.insert(bootScripts, path)
    end
end

-- So they are in order
table.sort(bootScripts)
for i = 1, #bootScripts do
    status("> " .. tostring(bootScripts[i]))
    dofile(bootScripts[i])
end

-- Tell the system that initialization is complete.
computer.pushSignal("init")
-- Enter scheduler loop
require("sys.kernel.modules.event").pull("init", 1)
