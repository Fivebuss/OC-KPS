-- /bin/sterm.lua
-- As tty and term are still pretty linked I just combined some jobs together
-- This makes life ALOT easier since you dont really interact with term directly

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

-- Get /dev/ttyN/attributes
local function attrRead()
    if not attrPath then return nil end
    local h, why = filesystem.open(attrPath, "r")
    if not h then return nil, why end
    local parts = {}
    while true do
        local chunk = h:read(2048)
        if not chunk then break end
        parts[#parts + 1] = chunk
    end
    h:close()
    return table.concat(parts)
end

-- send stuff to them
local function attrWrite(str)
    if not attrPath then return false end
    local h, why = filesystem.open(attrPath, "w")
    if not h then return false, why end
    h:write(str)
    h:close()
    return true
end

-- make it a real attribute
local function parseAttrs(str)
    local out = {}
    for tok in tostring(str or ""):gmatch("[^,%s]+") do
        local k, v = tok:match("^([^=]+)=(.*)$")
        if k and v then out[k] = v end
    end
    return out
end

-- Get resolution from /dev
local function getResolution()
    if attrPath then
        local data, why = attrRead()
        if not data then return 0, 0 end
        local t = parseAttrs(data)
        local res = t.resolution
        if res then
            local w, h = res:match("^(%d+)x(%d+)$")
            if w and h then return tonumber(w), tonumber(h) end
        end
        return 0, 0
    end
    if tty then return tty.w, tty.h end
    return 0, 0
end

local parsedArgs = {}
for i = argStart, #args do
    parsedArgs[#parsedArgs + 1] = args[i]
end
args = parsedArgs

local attrOps = {}

local function setAttr(key, val)
    if attrPath then
        attrOps[#attrOps + 1] = key .. "=" .. tostring(val)
    elseif tty then
        tty.attributes[key] = val
    end
end

if #args == 0 or args[1] == "-a" or args[1] == "all" then
    local w, h = getResolution()
    if attrPath then
        local data, why = attrRead()
        if data then
            io.writeln(data)
        else
            io.stderr:writeln("stty: cannot read attributes: " .. tostring(why))
            os.exit(1)
        end
    else
        io.writeln(string.format(
            "resolution %dx%d;\necho=%s; line=%s; raw=%s; cursor=%s; xoff=%s;\ndisabled signals: ^C=%s, ^Z=%s, ^D=%s",
            w, h,
            tostring(tty.attributes.echo),
            tostring(tty.attributes.line),
            tostring(tty.attributes.raw),
            tostring(tty.attributes.cursor),
            tostring(tty.attributes.xoff),
            tostring(tty.disabled.C or false),
            tostring(tty.disabled.Z or false),
            tostring(tty.disabled.D or false)
        ))
    end
    os.exit(0)
end

for _, arg in ipairs(args) do
    if arg == "sane" then
        if attrPath then
            attrOps[#attrOps + 1] = "echo=true"
            attrOps[#attrOps + 1] = "line=true"
            attrOps[#attrOps + 1] = "raw=false"
            attrOps[#attrOps + 1] = "xoff=false"
            attrOps[#attrOps + 1] = "cursor=true"
        elseif tty then
            tty.attributes.echo = true
            tty.attributes.line = true
            tty.attributes.raw = false
            tty.attributes.xoff = false
            tty:setCursor(true)
            tty.disabled = {}
        end
    elseif arg == "size" then
        local w, h = getResolution()
        io.writeln(string.format("%d %d", h, w))
    elseif arg == "echo" then
        setAttr("echo", true)
    elseif arg == "-echo" then
        setAttr("echo", false)
    elseif arg == "line" then
        setAttr("line", true)
    elseif arg == "-line" then
        setAttr("line", false)
    elseif arg == "raw" then
        setAttr("raw", true)
    elseif arg == "-raw" then
        setAttr("raw", false)
    elseif arg == "cursor" then
        setAttr("cursor", true)
    elseif arg == "-cursor" then
        setAttr("cursor", false)
    elseif arg == "xoff" then
        setAttr("xoff", true)
    elseif arg == "-xoff" then
        setAttr("xoff", false)
    elseif arg:sub(1, 11) == "resolution=" then
        local w, h = arg:match("^resolution=(%d+)x(%d+)$")
        if w and h then
            if attrPath then
                attrOps[#attrOps + 1] = "resolution=" .. w .. "x" .. h
            elseif tty then
                tty:setResolution(tonumber(w), tonumber(h))
            end
        end
    elseif arg == "intr" then
        if tty then tty.disabled.C = false end
    elseif arg == "-intr" then
        if tty then tty.disabled.C = true end
    elseif arg == "susp" then
        if tty then tty.disabled.Z = false end
    elseif arg == "-susp" then
        if tty then tty.disabled.Z = true end
    elseif arg == "eof" then
        if tty then tty.disabled.D = false end
    elseif arg == "-eof" then
        if tty then tty.disabled.D = true end
    end
end

if attrPath and #attrOps > 0 then
    attrWrite(table.concat(attrOps, " "))
end

os.exit(0)
