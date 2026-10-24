-- /lib/network/proto/ethernet.lua
-- eth0
-- No, wlo1 will not happen. Horrific spec...

local const   = require("network.const")

local M       = {}

local ifaces  = {}
local byName  = {}
local handler = nil    -- (iface, srcHw, etype, payload)
local mtuOverride

function M.setHandler(fn)
    handler = fn
end

function M.setMtuOverride(mtu)
    mtuOverride = mtu
end

local function computeMtu(iface)
    if mtuOverride and mtuOverride > 0 then
        return mtuOverride
    end
    local ok, info = pcall(function()
        if not computer or not computer.getDeviceInfo then return nil end
        return computer.getDeviceInfo()
    end)
    if ok and type(info) == "table" and iface.hw and info[iface.hw] then
        local device = info[iface.hw]
        local capacity = device and device.capacity
        if type(capacity) == "number" and capacity > 72 then
            return capacity - 72
        end
    end
    return const.DEFAULTS.mtu
end

-- The actual port and makes a registered thing around the proxy
function M.add(data)
    local iface = {
        name = data.name or data.hw,
        hw = data.hw,
        modem = data.modem,
        addr = data.addr,
        prefix = data.prefix,
        mask = data.mask,
    }

    local open = iface.modem.open and select(1, pcall(iface.modem.open, const.ETHER_PORT))
    if not open then
        return nil, "cannot open raw port " .. tostring(const.ETHER_PORT) ..
            " on " .. tostring(iface.hw)
    end

    iface.mtu = computeMtu(iface)
    ifaces[iface.hw] = iface
    byName[iface.name] = iface
    if handler then
        pcall(handler, "add", iface)
    end
    return iface
end

-- Remove an interface and close the port
function M.remove(iface)
    if type(iface) == "string" then
        iface = byName[iface] or nil
    end
    if type(iface) ~= "table" then
        return nil, "unknown interface"
    end
    local hw = iface.hw
    pcall(iface.modem.close, const.ETHER_PORT)
    if ifaces[hw] == iface then
        ifaces[hw] = nil
        byName[iface.name] = nil
    end
    if handler then
        pcall(handler, "remove", iface)
    end
    return true
end

function M.get(nameOrHw)
    return byName[nameOrHw] or ifaces[nameOrHw]
end

function M.list()
    local out = {}
    local n = 0
    for _, iface in pairs(ifaces) do
        n = n + 1
        out[n] = iface
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function M.clear()
    for hw, iface in pairs(ifaces) do
        pcall(iface.modem.close, const.ETHER_PORT)
    end
    ifaces = {}
    byName = {}
end

-- Sends an L2 frame
function M.send(iface, dstHw, etype, payload)
    if type(iface) ~= "table" or not iface.modem then
        return nil, "no interface"
    end
    local ok, reason
    if dstHw == const.MAC_BROADCAST then
        ok, reason = pcall(iface.modem.broadcast, const.ETHER_PORT, etype, payload)
    else
        ok, reason = pcall(iface.modem.send, dstHw, const.ETHER_PORT, etype, payload)
    end
    if not ok then
        return nil, "modem send failed: " .. tostring(reason)
    end
    return true
end

-- Deal with modem events
function M.onModemMessage(_, localHw, remoteHw, port, ...)
    if port ~= const.ETHER_PORT then
        return
    end
    local iface = ifaces[localHw]
    if not iface then
        return
    end
    local args = table.pack(...)

    if type(args[1]) == "number" then
        table.remove(args, 1)
    end
    local etype = args[1]
    local payload = args[2]
    if type(etype) ~= "number" or type(payload) ~= "string" then
        return
    end
    if handler then
        pcall(handler, "frame", iface, remoteHw, etype, payload)
    end
end

return M
