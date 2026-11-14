-- /bin/reset.lua
-- Resets terminal emulator to fix my ass readline
-- Yes I know sterm/stty does parts of this too. No I wont change it (for a while)
-- Until I figure out pts/pty stuff

local filesystem = require("filesystem")

local args = { ... }

-- Support /dev/tty<whatever>
local ttyDev = nil
local argStart = 1
if #args > 0 then
    local first = args[1]
    if first:match("^/dev/tty%d+$") then
        ttyDev = first
        argStart = 2
    elseif first:match("^tty%d+$") then
        ttyDev = "/dev/" .. first
        argStart = 2
    end
end

local tty = _G.ctty
local attrPath = ttyDev and (ttyDev .. "/attributes") or nil

-- Does it
local function resetTty(t)
    t.attributes.echo = true
    t.attributes.line = true
    t.attributes.raw = false
    t.attributes.cursor = true
    t.attributes.xoff = false
    t.disabled = {}
    t:setResolution(t.gpu.maxResolution())
    t.gpu.setActiveBuffer(0)
    t:setCursor(true)
    t:setCursorVisible(true)
    t:setCursorShape("underline")
    t:clear()
    t:removeDiscipline()
    t:resetColors()
end

if tty then
    resetTty(tty)
elseif attrPath then
    local h, why = io.open(attrPath, "w")
    if not h then
        io.stderr:writeln("reset: cannot open " .. attrPath .. ": " .. tostring(why))
        os.exit(1)
    end
    h:write("echo=true line=true raw=false cursor=true xoff=false")
    h:close()
else
    io.stderr:writeln("reset: no tty available")
    os.exit(1)
end

os.exit(0)
