-- Registers devfs stuff
-- yeah for now just has the basics

local component = require("component")

local devfs = polaris.devfs
local adapters = devfs.adapters

local devices = {
    null = {
        open = function()
            return {
                read = function() end,
                write = function() end
            }
        end
    },

    random = {
        open = function(mode)
            if mode and not mode:match("r") then
                return nil, "read only"
            end
            return {
                read = function(_, n)
                    local chars = {}
                    for _ = 1, n do
                        table.insert(chars, string.char(math.random(0, 255)))
                    end
                    return table.concat(chars)
                end
            }
        end
    },

    zero = {
        open = function()
            return {
                read = function(_, n) return ("\0"):rep(n) end,
                write = function() end
            }
        end
    },
}

for name, proxy in pairs(devices) do
    devfs.create(name, proxy)
end

local function is_tmp(addr)
    return addr == computer.tmpAddress()
end

local function snapshot()
    local list = {}
    for addr, ptype in component.list() do
        if not is_tmp(addr) then
            table.insert(list, { addr, ptype })
        end
    end
    table.sort(list, function(a, b) return a[1] < b[1] end)
    return list
end

local function component_faces(addr, ptype)

    local proxy = adapters.proxy(addr)
    if not proxy then return {} end
    local ok, slot = pcall(function() return proxy.slot end)
    local faces = {
        address = { addr },
        type = { ptype },
        slot = { ok and type(slot) == "number" and slot or 0 },
        device = { device = proxy },
    }
    local adapter = adapters.get(ptype)
    if adapter then
        local built_ok, built = pcall(adapter, proxy)
        if built_ok and type(built) == "table" then
            for name, face in pairs(built) do
                if faces[name] == nil then faces[name] = face end
            end
        else
            faces.error = { built_ok and "adapter returned no faces" or tostring(built) }
        end
    end
    -- Things can disappear now I know revolutionally
    for _, face in pairs(faces) do
        if type(face) == "table" then
            if type(face.read) == "function" then face.read = devfs.prepare(face.read) end
            if type(face.write) == "function" then face.write = devfs.prepare(face.write) end
        end
    end
    return faces
end

local function by_address()
    local faces = {}
    for _, entry in ipairs(snapshot()) do
        local addr, ptype = entry[1], entry[2]
        faces[addr] = { list = function()
            return component_faces(addr, ptype)
        end }
    end
    return faces
end

local function by_type()
    local list = snapshot()
    local primaries, counts, faces = {}, {}, {}
    for _, entry in ipairs(list) do
        local addr, ptype = entry[1], entry[2]
        if ptype == "filesystem" and addr == computer.getBootAddress() then
            primaries[ptype] = addr
        elseif primaries[ptype] == nil and component.isPrimary(addr) then
            primaries[ptype] = addr
        end
    end
    for _, entry in ipairs(list) do
        local ptype = entry[2]
        if primaries[ptype] == nil then
            primaries[ptype] = entry[1]
        end
    end
    for _, entry in ipairs(list) do
        local addr, ptype = entry[1], entry[2]
        if addr == primaries[ptype] then
            faces[ptype] = { link = "../by-address/" .. addr }
        else
            local n = (counts[ptype] or 0) + 1
            counts[ptype] = n
            faces[ptype .. n] = { link = "../by-address/" .. addr }
        end
    end
    return faces
end

local function filesystem_addrs()
    local addrs = {}
    for addr in component.list("filesystem", true) do
        if not is_tmp(addr) then
            table.insert(addrs, addr)
        end
    end
    table.sort(addrs)
    return addrs
end

-- local function by_label()
--
--     local faces, used = {}, {}
--     for _, addr in ipairs(filesystem_addrs()) do
--         local proxy = adapters.proxy(addr)
--         local ok, label = false, nil
--         if proxy then
--             ok, label = pcall(proxy.getLabel)
--         end
--         if ok and type(label) == "string" and label:len() > 0 and not used[label] then
--             used[label] = true
--
--             faces[label] = { link = "../by-address/" .. addr }
--         end
--     end
--     return faces
-- end

local function disks_faces()
    local faces, used = {}, {}
    for _, addr in ipairs(filesystem_addrs()) do
        local short = addr:sub(1, 3)
        if not used[short] then
            used[short] = true
            faces[short] = { link = "components/by-address/" .. addr }
        end
    end
    return faces
end

local function eeprom_faces()
    local addrs = {}
    for addr in component.list("eeprom", true) do
        table.insert(addrs, addr)
    end
    if #addrs == 0 then return {} end
    table.sort(addrs)
    local chosen = addrs[1]
    for _, addr in ipairs(addrs) do
        if component.isPrimary(addr) then
            chosen = addr
            break
        end
    end
    return { eeprom = { link = "components/by-address/" .. chosen } }
end

devfs.define("components", function()
    return {
        components = { list = function()
            return {
                ["by-address"] = { list = by_address },
                ["by-type"] = { list = by_type },
                ["by-label"] = { list = by_label },
            }
        end },
    }
end)
devfs.define("disks", disks_faces)
devfs.define("eeprom", eeprom_faces)
