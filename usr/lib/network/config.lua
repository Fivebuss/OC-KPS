--[[
/usr/lib/network/config.lua
deals with /etc/network/interfaces and /etc/network/knetd.cfg
Thanks AI for this bigass comment block --V
/etc/network/interfaces is like (subset):
  auto <name>...
  iface <name> inet static
      address <a.b.c.d/<prefix>>
      gateway <a.b.c.d>
      metric <n>
      mtu <n>

Only "inet static" is supported; "auto <n>" marks <n> for automatic bring
up. "lo" is implicit in knetd; an explicit lo block overrides the implicity
one. Interface names may be eth<slot>, lnk<slot> (linked cards) or an exact
modem/tunnel component UUID.
Invalid values are collected in the result; the entry simply never goes up

/etc/network/knetd.cfg holds simple key=value runtime options and defaults live in usr/lib/network/const.lua.
--]]

local M = {}

local function readFile(path)
    local filesystem = require("filesystem")
    if not filesystem.exists(path) then
        return nil
    end
    local file, reason = filesystem.open(path, "r")
    if not file then
        return nil, reason
    end
    local chunks = {}
    while true do
        local chunk = file:read(1024)
        if not chunk or chunk == "" then break end
        chunks[#chunks + 1] = chunk
    end
    file:close()
    local data = table.concat(chunks)
    if data == "" then
        return nil
    end
    return data
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end


function M.parseInterfaces(text)
    local out = {
        autos = {},
        ifaces = {},
        errors = {},
    }
    if type(text) ~= "string" or text == "" then
        return out
    end

    local lines = {}
    for line in text:gmatch("[^\n]+") do
        -- Just trailing whitespace and comments. I kinda need leading
        local stripped = line:match("^(.-)#.*$") or line
        stripped = stripped:gsub("%s+$", "")
        if stripped:find("%S", 1, false) then
            lines[#lines + 1] = stripped
        end
    end

    local current = nil

    for _, line in ipairs(lines) do
        local firstChar = line:sub(1, 1)
        local content = trim(line)

        if firstChar ~= " " and firstChar ~= "\t" then
            local keyword, rest = content:match("^(%S+)%s+(.*)$")
            keyword = keyword or content
            rest = rest or ""

            if keyword == "auto" then
                for name in rest:gmatch("%S+") do
                    out.autos[name] = true
                end
                current = nil
            elseif keyword == "iface" then
                local name, proto = content:match("^iface%s+(%S+)%s+inet%s+(%S+)%s*$")
                if not name then
                    name = content:match("^iface%s+(%S+)%s*$")
                    proto = name and "static"
                end
                if name then
                    current = out.ifaces[name]
                    if not current then
                        current = { errors = {} }
                        out.ifaces[name] = current
                    end
                    current.proto = proto
                    if proto ~= "static" then
                        out.errors[#out.errors + 1] =
                            name .. ": unsupported inet method (" ..
                            tostring(proto) .. "), only static"
                    end
                else
                    out.errors[#out.errors + 1] =
                        "interfaces: malformed iface line: " .. content
                    current = nil
                end
            elseif keyword == "source" or keyword == "mapping" then
                out.errors[#out.errors + 1] =
                    "interfaces: unsupported directive: " .. keyword
                current = nil
            else
                out.errors[#out.errors + 1] =
                    "interfaces: unknown directive: " .. content
                current = nil
            end
        else
            -- indent
            if not current then
                out.errors[#out.errors + 1] =
                    "interfaces: indented line outside iface block: " .. content
            else
                local key, value = content:match("^(%S+)%s+(.-)$")
                key = key or ""
                value = value and trim(value) or nil
                if key == "address" then
                    if value then
                        current.address = value
                    else
                        out.errors[#out.errors + 1] =
                        "interfaces: address needs a value"
                    end
                elseif key == "gateway" then
                    if value then
                        current.gateway = value
                    else
                        out.errors[#out.errors + 1] =
                        "interfaces: gateway needs a value"
                    end
                elseif key == "metric" then
                    local n = tonumber(value)
                    if n then
                        current.metric = n
                    else
                        out.errors[#out.errors + 1] =
                            "interfaces: metric not a number: " .. tostring(value)
                    end
                elseif key == "mtu" then
                    local n = tonumber(value)
                    if n then
                        current.mtu = n
                    else
                        out.errors[#out.errors + 1] =
                            "interfaces: mtu not a number: " .. tostring(value)
                    end
                else
                    current.errors[key] = true
                    out.errors[#out.errors + 1] =
                        "interfaces: unsupported attribute: " .. key
                end
            end
        end
    end

    return out
end

function M.loadInterfaces()
    local text = readFile("/etc/network/interfaces")
    return M.parseInterfaces(text)
end

-- knetd.cfg
function M.parseOptions(text, defaults)
    local opts = {}
    for key, value in pairs(defaults or {}) do
        opts[key] = value
    end
    if type(text) ~= "string" then
        return opts
    end
    for line in text:gmatch("[^\n]+") do
        local content = (line:match("^(.-)#.*$") or line)
        content = trim(content)
        if content ~= "" then
            local key, value = content:match("^([%w_]+)%s*=%s*(.-)$")
            if key then
                value = trim(value)
                if value == "true" then
                    opts[key] = true
                elseif value == "false" then
                    opts[key] = false
                elseif tonumber(value) then
                    opts[key] = tonumber(value)
                else
                    opts[key] = value
                end
            else
                opts["__errors"] = opts["__errors"] or {}
                opts.__errors[#opts.__errors + 1] = line
            end
        end
    end
    return opts
end

function M.loadOptions(defaults)
    local text = readFile("/etc/network/knetd.cfg")
    return M.parseOptions(text, defaults or {})
end

return M
