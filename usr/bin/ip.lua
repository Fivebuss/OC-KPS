-- /usr/bin/ip.lua
-- Deal with interfaces and static routes

local network = require("network")

local args = { ... }

local function usage()
    io.writeln("usage: ip [a | addr | address] | [r | route] |")
    io.writeln("       ip route add <net> [via <gw>] [dev <iface>] [metric <n>]")
    io.writeln("       ip route del <id | net/prefix>")
    io.writeln("       ip ifup <iface> | ip ifdown <iface>")
end

local function fail(what, err)
    io.writelnError("ip: " .. tostring(what) .. ": " .. tostring(err))
    os.exit(1)
    return false
end

local function showInterfaces()
    local interfaces, err = network.admin.interfaces()
    if not interfaces then
        return fail("interfaces", err)
    end
    for _, iface in ipairs(interfaces) do
        local flags = iface.up and "UP" or "DOWN"
        io.writeln(string.format(
            "%s: %s mtu %d",
            iface.name, flags, iface.mtu or 0
        ))
        io.writeln("    hw " ..
            ((iface.hw and iface.hw ~= "") and iface.hw or "(virtual)"))
        if iface.addr then
            io.writeln(string.format(
                "    inet %s/%d", iface.addr, iface.prefix or 0
            ))
        end
    end
    return true
end

local function showRoutes()
    local routes, err = network.admin.routes()
    if not routes then
        return fail("routes", err)
    end
    for _, rt in ipairs(routes) do
        local line = string.format("%s/%s", rt.network, rt.prefix)
        if rt.gateway then
            line = line .. " via " .. rt.gateway
        end
        line = line .. string.format(
            " dev %s metric %d id %d",
            rt.iface, rt.metric or 0, rt.id
        )
        io.writeln(line)
    end
    return true
end

-- route add
local function routeAdd(rest)
    local net = rest[1]
    if net == nil then
        usage()
        io.writelnError("ip: route add: net required (a.b.c.d/p)")
        os.exit(1)
        return false
    end

    local via, dev, metric
    local i = 2
    while i <= #rest do
        local token = rest[i]
        if token == "via" then
            via = rest[i + 1]
            i = i + 2
        elseif token == "dev" then
            dev = rest[i + 1]
            i = i + 2
        elseif token == "metric" then
            metric = tonumber(rest[i + 1])
            if metric == nil then
                io.writelnError("ip: route add: invalid metric: " ..
                    tostring(rest[i + 1]))
                os.exit(1)
                return false
            end
            i = i + 2
        else
            io.writelnError("ip: route add: unknown option: " .. tostring(token))
            os.exit(1)
            return false
        end
    end

    local route, err = network.admin.routeAdd(net, via, dev, metric)
    if not route then
        return fail("route add", err)
    end

    io.writeln(string.format(
        "added route %s/%s dev %s metric %d id %d",
        route.network, route.prefix, route.iface, route.metric or 0, route.id
    ))
    return true
end

-- route del <id | net/prefix>
local function routeDel(rest)
    local spec = rest[1]
    if spec == nil then
        usage()
        io.writelnError("ip: route del: route id or net required")
        os.exit(1)
        return false
    end

    local asId = tonumber(spec)
    if asId ~= nil and asId % 1 == 0 then
        spec = asId
    end

    local ok, err = network.admin.routeDel(spec)
    if not ok then
        return fail("route del", err)
    end
    io.writeln("deleted route " .. tostring(spec))
    return true
end

-- ip ifup/ifdown <interface>
local function ifaceUpDown(up, rest)
    local name = rest[1]
    if name == nil then
        usage()
        io.writelnError("ip: " .. (up and "ifup" or "ifdown") ..
            ": interface name required")
        os.exit(1)
        return false
    end
    local ok, err
    if up then
        ok, err = network.admin.ifup(name)
    else
        ok, err = network.admin.ifdown(name)
    end
    if not ok then
        return fail(up and "ifup" or "ifdown", err)
    end
    io.writeln(name .. ": " .. (up and "up" or "down"))
    return true
end

local cmd = args[1] or "a"

if cmd == "a" or cmd == "addr" or cmd == "address" then
    showInterfaces()
elseif cmd == "r" or cmd == "route" or cmd == "routes" then
    if args[2] == "add" then
        routeAdd({ table.unpack(args, 3) })
    elseif args[2] == "del" or args[2] == "delete" then
        routeDel({ table.unpack(args, 3) })
    else
        showRoutes()
    end
elseif cmd == "ifup" then
    ifaceUpDown(true, { table.unpack(args, 2) })
elseif cmd == "ifdown" then
    ifaceUpDown(false, { table.unpack(args, 2) })
elseif cmd == "h" or cmd == "help" or cmd == "-h" or cmd == "--help" then
    usage()
else
    usage()
    io.writelnError("ip: unknown command: " .. tostring(cmd))
    os.exit(1)
    return false
end

os.exit(0)
return false
