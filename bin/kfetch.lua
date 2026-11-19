-- /bin/kfetch.lua
-- Any OS nearing release needs this lol
local filesystem = require("filesystem")
local unicode = require("unicode")
local getopt = require("ksh.getopt")

-- fancy isnt it
local logo = [[
╔═══════════════════════════════╗
║'##:::'##:'########:::'######::║
║ ##::'##:: ##.... ##:'##... ##:║
║ ##:'##::: ##:::: ##: ##:::..::║
║ #####:::: ########::. ######::║
║ ##. ##::: ##.....::::..... ##:║
║ ##:. ##:: ##::::::::'##::: ##:║
║ ##::. ##: ##::::::::. ######::║
║..::::..::..::::::::::......:::║
╚═══════════════════════════════╝
]]

local smallLogoArt = [[
┌──────────────────────┐
│#    # ######   ##### │
│#   #  #     # #     #│
│#  #   #     # #      │
│###    ######   ##### │
│#  #   #             #│
│#   #  #       #     #│
│#    # #        ##### │
└──────────────────────┘
]]

local verbose = false
local showLogo = true
local smallLogo = false

-- logo?
for opt, val in getopt(args or {}, "vls", { verbose = "v", ["no-logo"] = "l", small = "s" }) do
    if opt == "v" then
        verbose = true
    elseif opt == "l" then
        showLogo = false
    elseif opt == "s" then
        smallLogo = true
    elseif opt == "?" then
        io.writelnError("kfetch: unrecognized option '" .. tostring(val) .. "'")
    end
end

local function verbosePrint(msg)
    if verbose then
        io.writeln(msg)
    end
end

local function getEnvVar(name)
    if type(getenv) == "function" then
        return getenv(name)
    end
    return os.getenv and os.getenv(name) or nil
end

-- Yes I use KiB here
local function formatSize(size)
    local suffixes = { "", "Ki", "Mi", "Gi" }
    local unit = 1
    while size >= 1024 and unit < #suffixes do
        unit = unit + 1
        size = size / 1024
    end
    return math.floor(size * 10) / 10 .. suffixes[unit] .. "B"
end

local function formatUptime(seconds)
    seconds = math.floor(seconds or 0)
    if seconds < 60 then
        return seconds .. " secs"
    elseif seconds < 3600 then
        return math.floor(seconds / 60) .. " mins"
    elseif seconds < 86400 then
        return math.floor(seconds / 3600) .. " hours"
    end
    return math.floor(seconds / 86400) .. " days"
end

-- Sizing...
local function splitLogo(text)
    local result = {}
    for line in text:gmatch("[^\n]+") do
        result[#result + 1] = line
    end
    return result
end

local function displayWidth(text)
    return (unicode.len or string.len)(text)
end

-- Tiers of things
local function tierText(tier, isApu)
    if not tier then return "" end
    if isApu then return " (Tier " .. tier .. " APU)" end
    return " (Tier " .. tier .. ")"
end

local function cpuTier(product, clock)
    local n = product and tostring(product):match("FlexiArch%s+(%d)")
    if n then return tonumber(n) end
    local c = tonumber(clock)
    if c then
        if c >= 1500 then return 3 end
        if c >= 1000 then return 2 end
    end
    return nil
end

local function gpuTier(product, width)
    local n = product and tostring(product):match("MPG(%d)")
    if n then return tonumber(n) end
    local w = tonumber(width)
    if w then
        if w >= 8 then return 3 end
        if w >= 4 then return 2 end
    end
    return nil
end

-- Why you gotta be so weird?
local function apuTier(product, width, clock)
    local n = product and tostring(product):match("FlexiArch%s+(%d)")
    if n then return tonumber(n) + 1 end
    local w = tonumber(width)
    if w then
        if w >= 8 then return 4 end
        if w >= 4 then return 3 end
    end
    local c = tonumber(tostring(clock or ""):match("^([^+]+)"))
    if c then
        if c >= 1500 then return 4 end
        if c >= 1000 then return 3 end
    end
    return nil
end

local lines = {}

local function add(label, value)
    lines[#lines + 1] = label .. ": " .. tostring(value)
end

verbosePrint("Discovering hardware")
local devices = computer.getDeviceInfo() or {}

local addresses = {}
for addr in pairs(devices) do
    addresses[#addresses + 1] = addr
end
table.sort(addresses)

local host
local cpuClock
local cpuTierLevel
local cpuIsApu
local gpus = {}

-- Here we go
for _, addr in ipairs(addresses) do
    local item = devices[addr]
    if type(item) == "table" then
        if item.class == "system" and not host then
            host = addr
        elseif item.class == "processor" and item.clock ~= nil and not cpuClock then
            local isApu = item.description == "APU"
                or (item.product and tostring(item.product):find("Builtin Graphics", 1, true) ~= nil)
            local clock = tostring(item.clock)
            cpuIsApu = isApu
            if isApu then
                cpuTierLevel = apuTier(item.product, item.width, item.clock)
            else
                cpuTierLevel = cpuTier(item.product, item.clock)
            end
            if isApu then
                local cpuPart, gpuPart = clock:match("^([^+]+)%+(.+)$")
                cpuClock = cpuPart or clock
                if gpuPart then
                    gpus[#gpus + 1] = {
                        width = tonumber(item.width) or 0,
                        tier = cpuTierLevel,
                        isApu = true,
                        text = (item.width and (item.width .. "-bit ") or "") .. gpuPart,
                    }
                end
            else
                cpuClock = clock
            end
        elseif item.class == "display" and item.clock ~= nil then
            gpus[#gpus + 1] = {
                width = tonumber(item.width) or 0,
                tier = gpuTier(item.product, item.width),
                text = (item.width and (item.width .. "-bit ") or "") .. tostring(item.clock),
            }
        end
    end
end

verbosePrint("Got host")
verbosePrint("Got CPU")
verbosePrint("Got GPU")

add("User", getEnvVar("USER") or "?")
add("Host", host or "?")
add("Kernel", "Polaris " .. tostring(polaris.version.kernel))
add("Uptime", formatUptime(computer.uptime()))
add("Terminal", getEnvVar("TERM") or "?")

-- I want more info
local shellPath = getEnvVar("SHELL") or ""
local shellName = shellPath:match("([^/]+)%.lua$") or shellPath:match("([^/]+)$") or "ksh"
add("Shell", shellName .. " " .. (getEnvVar("VERSION") or "?"))
add("Cursor", (ctty and ctty.cursor and ctty.cursor.shape) or "?")
add("CPU", _VERSION .. " " .. tostring(cpuClock or "?") .. tierText(cpuTierLevel, cpuIsApu))

verbosePrint("Getting memory")

-- GC trick
local totalMemory = computer.totalMemory()
local freeMemory = 0
for _ = 1, 10 do
    freeMemory = math.max(freeMemory, computer.freeMemory())
    computer.pullSignal(0)
end
local usedMemory = totalMemory - freeMemory
local memPercent = totalMemory > 0 and math.floor(usedMemory / totalMemory * 100) or 0

add("Memory", formatSize(usedMemory) .. " / " .. formatSize(totalMemory) .. " (" .. memPercent .. "%)")
verbosePrint("Got memory")

-- Descending order based on tier (I hope)
table.sort(gpus, function(a, b)
    if a.isApu ~= b.isApu then return a.isApu == true end
    return a.width > b.width
end)
for i, gpu in ipairs(gpus) do
    add("GPU " .. i, gpu.text .. tierText(gpu.tier, gpu.isApu))
end

verbosePrint("Getting disks")
local function proxyCall(proxy, method)
    if not proxy[method] then return nil end
    local ok, result = pcall(proxy[method])
    return ok and result or nil
end

-- Fym 65535 free
local ignoredMounts = {
    ["/dev"] = true,
    ["/proc"] = true,
    ["/tmp"] = true,
}
local bootAddr = computer.getBootAddress()
if bootAddr then
    ignoredMounts["/mnt/" .. tostring(bootAddr):sub(1, 3)] = true
end

local function normalizePath(path)
    if path ~= "/" and path:sub(-1) == "/" then
        return path:sub(1, -2)
    end
    return path
end

local mounts = {}
local currMounts = filesystem.mounts()
while true do
    local proxy, path = currMounts()
    if not proxy then break end
    path = normalizePath(path)
    if not ignoredMounts[path] then
        if not mounts[proxy] or #path < #mounts[proxy] then
            mounts[proxy] = path
        end
    end
end

local mountList = {}
for proxy, path in pairs(mounts) do
    mountList[#mountList + 1] = { proxy = proxy, path = path }
end
table.sort(mountList, function(a, b) return a.path < b.path end)

for _, entry in ipairs(mountList) do
    local used = proxyCall(entry.proxy, "spaceUsed") or 0
    local total = proxyCall(entry.proxy, "spaceTotal") or 0
    local percent = "0%"
    if total ~= math.huge and total > 0 then
        percent = math.floor(used / total * 100) .. "%"
    end
    local totalText = total == math.huge and "unlimited" or formatSize(total)
    add("Disk (" .. entry.path .. ")", formatSize(used) .. " / " .. totalText .. " (" .. percent .. ")")
end
verbosePrint("Got disks")

local infoIndent = 0

if showLogo then
    local art = splitLogo(smallLogo and smallLogoArt or logo)
    local logoWidth = 0
    for _, line in ipairs(art) do
        logoWidth = math.max(logoWidth, displayWidth(line))
    end
    infoIndent = logoWidth + 2
    for i = 1, math.max(#art, #lines) do
        local left = art[i] or ""
        local right = lines[i] or ""
        local coloredLeft = left ~= "" and ("\27[97m" .. left .. "\27[0m") or left
        io.writeln(coloredLeft .. string.rep(" ", logoWidth - displayWidth(left) + 2) .. right)
    end
else
    for _, line in ipairs(lines) do
        io.writeln(line)
    end
end

local function colorRow(first)
    local blocks = {}
    for i = first, first + 7 do
        local code = i < 8 and (30 + i) or (90 + i - 8)
        blocks[#blocks + 1] = "\27[" .. code .. "m██\27[0m"
    end
    return table.concat(blocks)
end

local colorPad = string.rep(" ", infoIndent)
io.writeln()
io.writeln(colorPad .. colorRow(0))
io.writeln(colorPad .. colorRow(8))
