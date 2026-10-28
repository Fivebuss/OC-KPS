-- /usr/lib/network/stack.lua
-- The actual knetd code to be honest
-- THIS IS ABHORRENTLY LONG

local const = require("network.const")
local wire = require("network.wire")
local ipc = require("network.ipc")
local address = require("network.address")
local config = require("network.config")

local ethernet = require("network.proto.ethernet")
local arp = require("network.proto.arp")
local ipv4 = require("network.proto.ipv4")
local icmp = require("network.proto.icmp")
local udp = require("network.proto.udp")
local tcp = require("network.proto.tcp")
local component = require("component")

local M = {}

local LOOPBACK_ADDR = 2130706433 -- 127.0.0.1
local WILDCARD_ADDR = 0          -- 0.0.0.0

local state = {
    pid = nil,
    running = false,
    cfg = {},
    conf = nil, -- /etc/network/interfaces
    listeners = {},
}

local ifaces = {}
local adminDown = {}

local function log(msg)
    pcall(function() polaris.log("knetd: " .. tostring(msg)) end)
end

local function debugLog(msg)
    if state.cfg and state.cfg.debug then
        log(msg)
    end
end

local computer = require("computer")
local computer_uptime = computer.uptime

local function now()
    return computer_uptime()
end

local function ifaceByHw(hw)
    for _, iface in pairs(ifaces) do
        if iface.hw == hw then
            return iface
        end
    end
    return nil
end

local function sortedIfaces()
    local out = {}
    for name in pairs(ifaces) do out[#out + 1] = ifaces[name] end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function ethSlotNumber(name)
    if type(name) ~= "string" then return nil end
    return tonumber(name:match("^eth(%d+)$"))
end

local function lnkSlotNumber(name)
    if type(name) ~= "string" then return nil end
    return tonumber(name:match("^lnk(%d+)$"))
end

-- Automatically added hopefully
local knownModems = {}
local knownTunnels = {}

local function componentAddresses(ctype, known)
    local raw = {}
    pcall(function()
        for addressStr, knownType in component.list() do
            if knownType == ctype then
                known[addressStr] = true
            end
        end
    end)
    for addressStr in pairs(known) do
        raw[#raw + 1] = addressStr
    end
    table.sort(raw)
    -- deduplication, though that shouldnt be possible. Except its happened
    local out, last = {}, nil
    for _, addressStr in ipairs(raw) do
        if addressStr ~= last then
            out[#out + 1] = addressStr
            last = addressStr
        end
    end
    return out
end

local function modemAddresses()
    return componentAddresses("modem", knownModems)
end

local function tunnelAddresses()
    return componentAddresses("tunnel", knownTunnels)
end

-- Resolved name to address
local function resolveModemAddress(name)
    local addresses = modemAddresses()
    local slot = ethSlotNumber(name)
    if slot == nil then
        for _, addressStr in ipairs(addresses) do
            if addressStr == name then return addressStr end
        end
        return nil
    end
    table.sort(addresses)
    return addresses[slot + 1]
end

-- Same deal but for linked cards (lnkN or a raw tunnel uuid)
local function resolveTunnelAddress(name)
    local addresses = tunnelAddresses()
    local slot = lnkSlotNumber(name)
    if slot == nil then
        for _, addressStr in ipairs(addresses) do
            if addressStr == name then return addressStr end
        end
        return nil
    end
    return addresses[slot + 1]
end

-- Address + routes, shared by modems and linked cards
local function provisionAddress(name, iface, entry)
    -- MTU from config
    if entry.mtu and entry.mtu > 0 then
        iface.mtu = entry.mtu
    end
    -- address provision
    iface.addr = nil
    iface.prefix = nil
    iface.mask = nil
    if entry.address then
        local addr, prefix = address.parseCIDR(entry.address)
        if addr then
            iface.addr = addr
            iface.prefix = prefix
            iface.mask = address.prefixToMask(prefix)
        else
            log(name .. ": bad address " .. tostring(entry.address) ..
                "; interface stays down")
        end
    end

    -- Subnet
    if iface.addr and iface.mask then
        local netDotted = address.dotted(address.networkOf(iface.addr, iface.mask))
        ipv4.addRoute({
            net = netDotted .. "/" .. tostring(iface.prefix),
            gateway = nil,
            metric = entry.metric,
            iface = name,
            ptp = iface.tunnel,
        })
        if entry.gateway then
            local gw = address.parse(entry.gateway)
            if gw then
                ipv4.addRoute({
                    net = "0.0.0.0/0",
                    gateway = gw,
                    metric = (entry.metric or 0) + 100,
                    iface = name,
                    ptp = iface.tunnel,
                })
            else
                log(name .. ": bad gateway " .. tostring(entry.gateway))
            end
        end
    end
end

-- Bring interfac up
local function raise(name, entry, preferAddress)
    if ifaces[name] then
        if name == "lo" or ifaces[name].hw then
            return true
        end
    end
    if name == "lo" then
        return nil, "lo is managed by knetd"
    end

    entry = entry or {}

    -- lnk slots are linked cards, other names try modems then tunnels
    local hw = preferAddress or resolveModemAddress(name) or resolveTunnelAddress(name)
    if hw == nil then
        if lnkSlotNumber(name) then
            return nil, "no linked card for interface " .. name
        end
        return nil, "no modem for interface " .. name
    end

    local ok, err = pcall(function()
        local proxy = component.proxy(hw)
        if proxy == nil or (proxy.type ~= "modem" and proxy.type ~= "tunnel") then
            error("not a network component: " .. tostring(hw), 0)
        end
        local iface, addErr = ethernet.add({
            name = name,
            hw = hw,
            modem = proxy,
        })
        if iface == nil then
            error(tostring(addErr), 0)
        end
        ifaces[name] = iface
        provisionAddress(name, iface, entry)
    end)

    if not ok then
        return nil, "raise failed: " .. tostring(err)
    end
    if not ifaces[name] then
        return nil, "raise failed: " .. name
    end
    log(name .. ": up (" .. tostring(ifaces[name].hw or "?") .. ")")
    return true
end

-- Hey dont bring lo down
local function lower(name)
    local iface = ifaces[name]
    if iface == nil then
        return nil, "no such interface"
    end
    if name == "lo" then
        return nil, "lo cannot be brought down"
    end

    ifaces[name] = nil
    adminDown[name] = true
    if iface.addr then
        udp.removeBoundTo(iface.addr)
        tcp.removeBoundTo(iface.addr)
    end
    arp.forgetIface(name)
    ipv4.delRoutesForIface(name)
    ethernet.remove(iface)
    log(name .. ": down")
    return true
end

local function createLoopbackIface()
    if ifaces.lo then return end
    ifaces.lo = {
        name = "lo",
        hw = nil, -- virtual
        modem = nil,
        addr = LOOPBACK_ADDR,
        prefix = 8,
        mask = address.prefixToMask(8),
        mtu = 16384,
        virtual = true,
    }
end

local function resolvePayload(item, src)
    if item.encode then
        local ok, payload = pcall(item.encode, src)
        if not ok then
            log("payload encoder failed: " .. tostring(payload))
            return nil
        end
        return payload
    end
    return item.payload
end

-- We can skip ALOT of time for lo
local sendIP
local udpNoSocket

local loopbackQueue = {}

local function deliverLocal(src, dst, proto, payload)
    if proto == const.PROTOCOLS.UDP then
        local msg = udp.decodeDatagram(payload, src, dst)
        if msg == nil then
            debugLog("udp decode failed")
            return
        end
        local sock = udp.findSocket(dst, src, msg.dport, msg.sport)
        if sock == nil then
            if udpNoSocket then
                pcall(udpNoSocket, src, dst, msg, payload)
            end
            debugLog("no udp socket for " .. (address.dotted(dst) or "?") .. ":" .. msg.dport)
            return
        end
        udp.deliver(sock, src, msg.sport, msg.payload)
    elseif proto == const.PROTOCOLS.TCP then
        local seg = tcp.decodeSegment(payload, src, dst)
        if seg == nil then
            debugLog("tcp decode failed")
            return
        end
        tcp.receive(src, dst, seg)
    elseif proto == const.PROTOCOLS.ICMP then
        local msg = icmp.decode(payload)
        if msg == nil then
            debugLog("icmp decode failed")
            return
        end
        icmp.receive(src, dst, msg)
    else
        debugLog("no local delivery for protocol " .. tostring(proto))
    end
end

-- Go here and go there
local function sendFragments(iface, hw, src, dst, proto, payload)
    local id = ipv4.nextId()
    local list, reason = ipv4.fragments(payload, iface.mtu or const.DEFAULTS.mtu, id)
    if list == nil then
        return nil, reason
    end
    for _, frag in ipairs(list) do
        local packet = ipv4.encodePacket({
            src = src,
            dst = dst,
            proto = proto,
            id = id,
            flags = frag.flags,
            offset = frag.offset,
            payload = frag.payload,
        })
        local ok, sendErr = ethernet.send(iface, hw, const.ETHER_TYPES.IPv4, packet)
        if not ok then
            return nil, sendErr
        end
    end
    return true
end

-- What route?
local function routeFor(dst)
    dst = dst % 4294967296
    local route = ipv4.lookup(dst)
    if route and route.iface ~= "lo" then
        return route
    end
    for name, iface in pairs(ifaces) do
        if iface.addr and iface.mask and name ~= "lo" then
            if wire.band32(dst, iface.mask) == address.networkOf(iface.addr, iface.mask) then
                return { iface = name, gateway = 0, mask = iface.mask, connected = true }
            end
        end
    end
    return nil
end

-- This is a big guy!
sendIP = function(item)
    if type(item) ~= "table" or item.dst == nil then
        return nil, "invalid send item"
    end
    local dst = item.dst % 4294967296

    -- lo skips lol
    if address.isLoopback(dst) then
        local src = (item.src and item.src ~= 0) and item.src or LOOPBACK_ADDR
        local payload = resolvePayload(item, src)
        if payload == nil then
            return nil, "encode failed"
        end
        loopbackQueue[#loopbackQueue + 1] = { src = src, dst = dst, proto = item.proto, payload = payload }
        return true
    end

    -- Recognize that we can ping ourselves lol
    for _, iface in pairs(ifaces) do
        if iface.addr == dst then
            local src = (item.src and item.src ~= 0) and item.src or dst
            local payload = resolvePayload(item, src)
            if payload == nil then
                return nil, "encode failed"
            end
            loopbackQueue[#loopbackQueue + 1] = { src = src, dst = dst, proto = item.proto, payload = payload }
            return true
        end
    end

    -- 255.255.255.255 by default
    local broadcastIface
    if dst == 4294967295 then
        for _, iface in pairs(ifaces) do
            if iface.name ~= "lo" and iface.hw then
                broadcastIface = iface
                break
            end
        end
    end
    if not broadcastIface then
        for name, iface in pairs(ifaces) do
            if iface.addr and iface.mask then
                if dst == address.broadcastOf(iface.addr, iface.mask) then
                    broadcastIface = iface
                    break
                end
            end
        end
    end
    if broadcastIface then
        if broadcastIface.addr == nil then
            return nil, "broadcast interface has no address"
        end
        local src = (item.src and item.src ~= 0) and item.src or broadcastIface.addr
        local payload = resolvePayload(item, src)
        if payload == nil then
            return nil, "encode failed"
        end
        return sendFragments(broadcastIface, const.MAC_BROADCAST, src, dst,
            item.proto, payload)
    end

    -- generic route
    local route = routeFor(dst)
    if route == nil then
        return nil, "no route to host"
    end
    local iface = ifaces[route.iface]
    if iface == nil or iface.hw == nil then
        return nil, "network unreachable"
    end

    local src = (item.src and item.src ~= 0) and item.src or iface.addr
    if src == nil then
        return nil, "no source address"
    end

    local gateway = route.gateway or 0
    local hop = gateway ~= 0 and gateway or dst

    local payloadResolved = resolvePayload(item, src)
    if payloadResolved == nil then
        return nil, "encode failed"
    end

    local hw = arp.lookup(iface.name, hop, now())
    if hw then
        return sendFragments(iface, hw, src, dst, item.proto, payloadResolved)
    end

    -- unresolved
    local queued, err = arp.enqueue(hop, iface, {
        iface = iface,
        src = src,
        dst = dst,
        proto = item.proto,
        encode = function()
            return resolvePayload(item, src)
        end,
    }, now())
    if queued == nil then
        return nil, err
    end
    arp.kick(iface, hop, now(), state.cfg.arpTimeout)
    return "queued"
end

-- ARP guy
local function arpSender(iface, ip, dstHw, rawFrame)
    if type(iface) ~= "table" or iface.modem == nil then
        return nil, "no interface"
    end
    if rawFrame == nil then
        if iface.addr == nil then
            return nil, "interface has no address"
        end
        rawFrame = arp.encode(arp.OPERATION.REQUEST, iface.hw, iface.addr,
            const.MAC_BROADCAST, ip)
        dstHw = const.MAC_BROADCAST
    end
    return ethernet.send(iface, dstHw or const.MAC_BROADCAST, const.ETHER_TYPES.ARP, rawFrame)
end

local function icmpSend(item)
    return sendIP(item)
end

udpNoSocket = function(src, dst, msg, datagram)
    if src == 0 or address.isLoopback(src) then return end
    if dst == 4294967295 then return end
    if wire.band32(dst, 4026531840) == 3758096384 then return end
    for _, iface in pairs(ifaces) do
        if iface.addr and iface.mask and
            dst == address.broadcastOf(iface.addr, iface.mask)
        then
            return
        end
    end
    local embedded = ipv4.encodePacket({
        src = src,
        dst = dst,
        proto = const.PROTOCOLS.UDP,
        id = 0,
        flags = 0,
        offset = 0,
        ttl = 64,
        payload = datagram:sub(1, 8),
    })
    sendIP({
        src = dst,
        dst = src,
        proto = const.PROTOCOLS.ICMP,
        payload = icmp.encodeError(icmp.TYPE.DEST_UNREACH, 3, 0, embedded),
    })
end


local function icmpNotify(clientPid, reqId, result)
    if type(clientPid) ~= "number" or type(result) ~= "table" then return end
    polaris.process.send(clientPid, {
        network = true,
        kind = "notify",
        pid = state.pid,
        id = reqId,
        op = "ping",
        type = result.type,
        dst = address.dotted(result.dst),
        icmpId = result.id,
        seq = result.seq,
        payload = result.payload,
    })
end

local function notifyClient(clientPid, message)
    polaris.process.send(clientPid, message)
end

local function arpFlushItem(entry, hw)
    if type(entry) ~= "table" or entry.iface == nil then return end
    local payload
    if entry.encode then
        payload = entry.encode(entry.src)
    else
        payload = entry.payload
    end
    if payload == nil then return end
    sendFragments(entry.iface, hw, entry.src, entry.dst, entry.proto, payload)
end

local function onEthernetAction(action, iface, srcHw, etype, payload)
    if action == "frame" then
        if etype == const.ETHER_TYPES.ARP then
            local frame = arp.decode(payload)
            if frame == nil then
                log("arp decode failed")
                return
            end
            arp.receive(iface, frame, now(), state.cfg.arpExpire)
        elseif etype == const.ETHER_TYPES.IPv4 then
            ipv4.receive(iface, payload, now())
        else
            debugLog("dropped etype " .. tostring(etype))
        end
    elseif action == "add" then
        debugLog("iface added " .. tostring(iface and iface.name))
    elseif action == "remove" then
        debugLog("iface removed " .. tostring(iface and iface.name))
    end
end

local function advertisedMss(localAddr, peerAddr)
    if (address.isLoopback(localAddr or 0) or address.isLoopback(peerAddr or 0))
        and ifaces.lo
    then
        return ifaces.lo.mtu - 40
    end
    local route = routeFor(peerAddr)
    local iface = route and ifaces[route.iface] or nil
    if iface and iface.mtu and iface.mtu >= 80 then
        return iface.mtu - 40
    end
    return const.TCP_MSS_FALLBACK
end

local function wireInjections()
    ethernet.setHandler(onEthernetAction)
    ethernet.setMtuOverride(state.cfg.mtu)

    arp.setFlush(arpFlushItem)
    arp.setRequestSender(arpSender)
    arp.setLog(log)

    ipv4.setLocalDeliver(function(msg)
        deliverLocal(msg.src, msg.dst, msg.proto, msg.payload)
    end)
    ipv4.setLog(log)
    ipv4.setDebug(function(msg) debugLog(msg) end)

    ipv4.setIsLocal(function(dst)
        if dst == LOOPBACK_ADDR then return true end
        for _, iface in pairs(ifaces) do
            if iface.addr == dst then return true end
        end
        return false
    end)

    ipv4.setForward(function(msg)
        -- split horizon: never bounce a packet back out the wire it came in on
        local route = routeFor(msg.dst)
        if route == nil or route.iface == msg.inIface then
            return
        end
        sendIP({
            src     = msg.src,
            dst     = msg.dst,
            proto   = msg.proto,
            payload = msg.payload,
        })
    end)

    icmp.setSendIP(icmpSend)
    icmp.setNotify(icmpNotify)
    icmp.setLog(log)
    icmp.setPmtudFn(function(eSrc, eDst, eSport, eDport, newMtu)
        tcp.setPmtudMss(eSrc, eDst, eSport, eDport, newMtu)
    end)

    udp.setNotify(notifyClient)
    udp.setLog(log)

    tcp.setSendIP(function(item) return sendIP(item) end)
    tcp.setNotify(notifyClient)
    tcp.setMssResolver(advertisedMss)
    tcp.setLog(log)
end
-- Event handlers

local function onModemMessageEvent(...)
    local args = table.pack(...)
    -- port 0 = linked card, real modems cant open port 0
    if args[4] ~= const.ETHER_PORT and args[4] ~= 0 then return end
    if state.pid then
        polaris.process.send(state.pid, {
            network = true,
            kind = "event",
            ev = "modem_message",
            args = args,
        })
    end
end

local function onComponentAdded(_, addressStr, ctype)
    if state.pid and (ctype == "modem" or ctype == "tunnel") then
        polaris.process.send(state.pid, {
            network = true,
            kind = "event",
            ev = "component_added",
            address = addressStr,
            ctype = ctype,
        })
    end
end

local function onComponentRemoved(_, addressStr, ctype)
    if state.pid and (ctype == "modem" or ctype == "tunnel") then
        polaris.process.send(state.pid, {
            network = true,
            kind = "event",
            ev = "component_removed",
            address = addressStr,
            ctype = ctype,
        })
    end
end

local function onTickTimer()
    if state.pid then
        polaris.process.send(state.pid, { network = true, kind = "tick" })
    end
end

local lastRetryError = {}

local function retryAutos()
    local conf = state.conf
    if conf == nil then return end

    for name in pairs(conf.autos or {}) do
        if not ifaces[name] then
            if adminDown[name] then
                lastRetryError[name] = nil
            else
                local ok, err = raise(name, conf.ifaces[name])
                if ok then
                    lastRetryError[name] = nil
                    log("ifup " .. name .. " (deferred: modem became visible)")
                elseif err ~= lastRetryError[name] then
                    lastRetryError[name] = err
                    debugLog("ifup retry " .. name .. ": " .. tostring(err))
                end
            end
        else
            lastRetryError[name] = nil
        end
    end
end

local function stackTick()
    local nowNum = now()

    -- Fix localhost TCP
    local drained = loopbackQueue
    loopbackQueue = {}
    for _, pkt in ipairs(drained) do
        deliverLocal(pkt.src, pkt.dst, pkt.proto, pkt.payload)
    end

    arp.tick(nowNum, {
        retries = state.cfg.arpRetries,
        timeout = state.cfg.arpTimeout,
    })
    ipv4.tick(nowNum)
    icmp.tick(nowNum)
    tcp.tick(nowNum)

    retryAutos()

    -- deal with sockets owned by dead clients
    for _, sock in ipairs(udp.list()) do
        if sock.owner ~= nil and not polaris.process.exists(sock.owner) then
            udp.remove(sock.id)
            log("socket " .. tostring(sock.id) .. ": owner " ..
                tostring(sock.owner) .. " is gone")
        end
    end
    for _, sock in ipairs(tcp.list()) do
        if sock.owner ~= nil and not polaris.process.exists(sock.owner) then
            tcp.abandon(sock.id)
            log("tcp socket " .. tostring(sock.id) .. ": owner " ..
                tostring(sock.owner) .. " is gone")
        end
    end
end

local function deferredReply(waiter, ok, payload)
    if type(waiter) ~= "table" or waiter.pid == nil then
        return
    end
    local out = {
        network = true,
        kind = "reply",
        id = waiter.reqId,
        pid = state.pid,
        ok = ok,
    }
    if ok and type(payload) == "table" then
        for key, value in pairs(payload) do
            out[key] = value
        end
    end
    if not ok then
        out.err = payload
    end
    polaris.process.send(waiter.pid, out)
end

local function replyTo(msg, ok, payload)
    if type(msg) ~= "table" then
        return
    end
    return deferredReply({ pid = msg.pid, reqId = msg.id }, ok, payload)
end

local function opInterfaces()
    local out = {}
    for i, iface in ipairs(sortedIfaces()) do
        out[i] = {
            name = iface.name,
            hw = iface.hw or "",
            addr = iface.addr and address.dotted(iface.addr) or nil,
            prefix = iface.prefix,
            mtu = iface.mtu or 0,
            up = iface.addr ~= nil,
        }
    end
    return true, { interfaces = out }
end

local function opIfup(msg, args)
    local name = args.name
    if type(name) ~= "string" or name == "" then
        return false, "interface name required"
    end
    state.conf = config.loadInterfaces()
    for _, errLine in ipairs(state.conf.errors or {}) do
        log("/etc/network/interfaces: " .. errLine)
    end
    adminDown[name] = nil
    local ok, err = raise(name, state.conf.ifaces[name])
    if not ok then
        return false, err
    end
    return true, {}
end

local function opIfdown(msg, args)
    local name = args.name
    if type(name) ~= "string" or name == "" then
        return false, "interface name required"
    end
    local ok, err = lower(name)
    if not ok then
        return false, err
    end
    return true, {}
end

local function opRoutes()
    local out = {}
    for i, route in ipairs(ipv4.list()) do
        out[i] = {
            id = route.id,
            network = address.dotted(route.network),
            prefix = route.prefix,
            gateway = route.gateway and route.gateway ~= 0 and
                address.dotted(route.gateway) or nil,
            metric = route.metric,
            iface = route.iface,
        }
    end
    return true, { routes = out }
end

local function opRouteAdd(msg, args)
    local net = args.net
    if type(net) ~= "string" then
        return false, "net required (a.b.c.d/p)"
    end
    local gateway
    if args.via ~= nil and args.via ~= "" then
        gateway = address.parse(args.via)
        if gateway == nil then
            return false, "invalid gateway"
        end
    end
    local dev = args.dev
    if dev ~= nil and dev ~= "" then
        if ifaces[dev] == nil then
            return false, "unknown interface " .. dev
        end
    else
        dev = nil
    end
    local metric
    if args.metric ~= nil then
        metric = tonumber(args.metric)
        if metric == nil then
            return false, "invalid metric"
        end
    end

    local route, err = ipv4.addRoute({
        net = net,
        gateway = gateway,
        metric = metric,
        iface = dev,
    })
    if route == nil then
        return false, err
    end
    return true, {
        route = {
            id = route.id,
            network = address.dotted(route.network),
            prefix = route.prefix,
            gateway = route.gateway ~= 0 and address.dotted(route.gateway) or nil,
            metric = route.metric,
            iface = route.iface,
        },
    }
end

local function opRouteDel(msg, args)
    local spec = args.route
    if spec == nil then
        return false, "route id or network required"
    end
    if type(spec) == "number" then
        if not ipv4.delRoute(spec) then
            return false, "no such route"
        end
        return true, {}
    end
    local network, prefix = address.parseCIDR(spec)
    if network == nil then
        return false, tostring(prefix)
    end
    local mask = address.prefixToMask(prefix)
    for _, route in ipairs(ipv4.list()) do
        if route.network == network and (prefix == 32 or route.prefix == prefix) then
            ipv4.delRoute(route.id)
            return true, {}
        end
    end
    -- fallback
    for _, route in ipairs(ipv4.list()) do
        if route.prefix >= prefix and wire.band32(route.network, mask) == network then
            ipv4.delRoute(route.id)
            return true, {}
        end
    end
    return false, "no such route"
end

local function opArp()
    local nowNum = now()
    local out = {}
    for i, entry in ipairs(arp.list()) do
        out[i] = {
            ip = address.dotted(entry.ip),
            ha = entry.hw,
            iface = entry.iface,
            remaining = math.max(0, math.ceil((entry.expires or 0) - nowNum)),
        }
    end
    table.sort(out, function(a, b) return tostring(a.ip) < tostring(b.ip) end)
    return true, { entries = out }
end

local function opArpFlush()
    arp.flushCache()
    return true, {}
end

local function opSockets()
    local out = {}
    for i, sock in ipairs(udp.list()) do
        out[i] = {
            id = sock.id,
            laddr = (sock.laddr and sock.laddr ~= 0) and address.dotted(sock.laddr) or "0.0.0.0",
            lport = sock.lport,
            raddr = (sock.raddr and sock.raddr ~= 0) and address.dotted(sock.raddr) or "0.0.0.0",
            rport = sock.rport,
            owner = sock.owner,
            queue = sock.queue and #sock.queue or 0,
        }
    end
    local tcpOut = {}
    for i, sock in ipairs(tcp.list()) do
        tcpOut[i] = {
            id = sock.id,
            state = sock.state,
            laddr = (sock.laddr and sock.laddr ~= 0) and address.dotted(sock.laddr) or "0.0.0.0",
            lport = sock.lport,
            raddr = (sock.raddr and sock.raddr ~= 0) and address.dotted(sock.raddr) or "0.0.0.0",
            rport = sock.rport,
            owner = sock.owner,
            queue = sock.rcvQueue and #sock.rcvQueue or 0,
        }
    end
    return true, { sockets = out, tcp = tcpOut }
end

local function opReload()
    state.conf = config.loadInterfaces()
    for _, errLine in ipairs(state.conf.errors or {}) do
        log("/etc/network/interfaces: " .. errLine)
    end
    local raised = {}
    for name in pairs(state.conf.autos) do
        if (ethSlotNumber(name) or lnkSlotNumber(name)) and
            not ifaces[name] and not adminDown[name]
        then
            local ok, err = raise(name, state.conf.ifaces[name])
            if ok then adminDown[name] = nil end
            raised[name] = ok or err
        end
    end
    return true, { raised = raised }
end

local function opUdpBind(msg, args)
    local laddr
    laddr = WILDCARD_ADDR
    if args.laddr ~= nil and args.laddr ~= "" then
        laddr = address.parse(args.laddr)
        if laddr == nil then
            return false, "invalid address"
        end
    end
    local lport = args.lport or 0
    local sock, err = udp.bind(laddr, lport, { owner = msg.pid })
    if sock == nil then
        return false, err
    end
    debugLog("udp bind id=" .. sock.id .. " " .. address.dotted(sock.laddr) ..
        ":" .. sock.lport .. " owner=" .. tostring(msg.pid))
    return true, {
        socketId = sock.id,
        addr = address.dotted(sock.laddr),
        port = sock.lport,
    }
end

local function opUdpConnect(msg, args)
    if type(args.socketId) ~= "number" then
        return false, "socketId required"
    end
    local raddr = address.parse(args.raddr)
    if raddr == nil then
        return false, "invalid remote address"
    end
    local sock, err = udp.connect(args.socketId, raddr, args.rport or 0)
    if sock == nil then
        return false, err
    end
    return true, {
        raddr = address.dotted(sock.raddr),
        rport = sock.rport,
    }
end

local function opUdpSend(msg, args)
    if type(args.socketId) ~= "number" then
        return false, "socketId required"
    end
    local sock = udp.get(args.socketId)
    if sock == nil then
        return false, "no such socket"
    end
    if sock.owner ~= msg.pid then
        return false, "not the socket owner"
    end
    if type(args.data) ~= "string" then
        return false, "data must be a string"
    end

    local dst
    if args.addr ~= nil and args.addr ~= "" then
        dst = address.parse(args.addr)
        if dst == nil then
            return false, "invalid address"
        end
    elseif sock.raddr and sock.raddr ~= 0 then
        dst = sock.raddr
    else
        return false, "not connected"
    end
    local dport = args.port
    if dport == nil or dport == 0 then
        if sock.rport and sock.rport ~= 0 then
            dport = sock.rport
        else
            return false, "no destination port"
        end
    end

    local encoder = function(src)
        return udp.encodeDatagram(sock.lport, dport, args.data, src, dst)
    end
    local sent, reason = sendIP({
        src = (sock.laddr and sock.laddr ~= 0) and sock.laddr or 0,
        dst = dst,
        proto = const.PROTOCOLS.UDP,
        encode = encoder,
    })
    if sent == nil then
        return false, reason
    end
    return true, { queued = sent == "queued" }
end

local function opUdpRecv(msg, args)
    if type(args.socketId) ~= "number" then
        return false, "socketId required"
    end
    local sock = udp.get(args.socketId)
    if sock == nil then
        return false, "no such socket"
    end
    if sock.owner ~= msg.pid then
        return false, "not the socket owner"
    end

    local entry = udp.shiftQueue(sock)
    if entry == nil then
        if sock.waiter then
            return false, "already waiting"
        end
        udp.setWaiter(sock, { pid = msg.pid, reqId = msg.id })
        return nil -- deferred
    end
    return true, {
        data = entry.data,
        from = entry.from and address.dotted(entry.from) or nil,
        port = entry.port,
    }
end

local function opUdpRecvCancel(msg, args)
    if type(args.socketId) ~= "number" then
        return false, "socketId required"
    end
    local sock = udp.get(args.socketId)
    if sock == nil then
        return true, {} -- nothing to cancel
    end
    if sock.owner ~= msg.pid then
        return false, "not the socket owner"
    end
    udp.cancelWaiter(sock, args.reqId)
    return true, {}
end

local function opUdpClose(msg, args)
    if type(args.socketId) ~= "number" then
        return false, "socketId required"
    end
    local sock = udp.get(args.socketId)
    if sock == nil then
        return true, {}
    end
    if sock.owner ~= msg.pid then
        return false, "not the socket owner"
    end
    udp.remove(args.socketId)
    debugLog("udp close id=" .. tostring(args.socketId))
    return true, {}
end

local function opPingRequest(msg, args)
    local dst, parseErr = address.parse(args.dst)
    if dst == nil then
        return false, "invalid destination: " .. tostring(parseErr)
    end
    if type(args.payload) ~= "string" then
        return false, "payload must be a string"
    end
    local timeout = tonumber(args.timeout) or const.DEFAULTS.icmpTimeout
    local icmpId = tonumber(args.id) or 0
    local seq = tonumber(args.seq) or 0

    local src
    if address.isLoopback(dst) then
        src = LOOPBACK_ADDR
    else
        local route = routeFor(dst)
        local iface = route and ifaces[route.iface] or nil
        if iface == nil then
            return false, "no route to host"
        end
        if iface.addr == nil then
            return false, "interface " .. tostring(route.iface) .. " has no address"
        end
        src = iface.addr
    end

    local requestPayload = icmp.encode(icmp.TYPE.ECHO_REQUEST, 0, icmpId, seq, args.payload)
    local key = icmp.beginRequest({
        src = src,
        dst = dst,
        icmpId = icmpId,
        seq = seq,
        payload = args.payload,
        timeout = timeout,
        ipcRequest = { pid = msg.pid, id = msg.id },
    }, now())

    local sent, reason = sendIP({
        src = src,
        dst = dst,
        proto = const.PROTOCOLS.ICMP,
        payload = requestPayload,
    })
    if sent == nil then
        icmp.dropRequest(src, dst, icmpId, seq)
        return false, reason
    end
    return true, { queued = sent == "queued", key = key }
end

local function opTcpBind(msg, args)
    local laddr
    laddr = WILDCARD_ADDR
    if args.laddr ~= nil and args.laddr ~= "" then
        laddr = address.parse(args.laddr)
        if laddr == nil then
            return false, "invalid address"
        end
    end
    local lport = args.lport or 0
    local sock, err = tcp.bind(laddr, lport, { owner = msg.pid })
    if sock == nil then
        return false, err
    end
    debugLog("tcp bind id=" .. sock.id .. " " .. address.dotted(sock.laddr) ..
        ":" .. sock.lport .. " owner=" .. tostring(msg.pid))
    return true, {
        socketId = sock.id,
        addr = address.dotted(sock.laddr),
        port = sock.lport,
    }
end

local function opTcpListen(msg, args)
    local laddr
    laddr = WILDCARD_ADDR
    if args.laddr ~= nil and args.laddr ~= "" then
        laddr = address.parse(args.laddr)
        if laddr == nil then
            return false, "invalid address"
        end
    end
    local lport = args.lport or 0
    local sock, err = tcp.listen(laddr, lport, { owner = msg.pid })
    if sock == nil then
        return false, err
    end
    debugLog("tcp listen id=" .. sock.id .. " " .. address.dotted(sock.laddr) ..
        ":" .. sock.lport .. " owner=" .. tostring(msg.pid))
    return true, {
        socketId = sock.id,
        addr = address.dotted(sock.laddr),
        port = sock.lport,
    }
end

local function opTcpConnect(msg, args)
    if type(args.socketId) ~= "number" then
        return false, "socketId required"
    end
    local sock = tcp.get(args.socketId)
    if sock == nil then
        return false, "no such socket"
    end
    if sock.owner ~= msg.pid then
        return false, "not the socket owner"
    end
    local raddr = address.parse(args.raddr)
    if raddr == nil then
        return false, "invalid remote address"
    end
    if type(args.rport) ~= "number" or args.rport < 1 or args.rport > 65535 or args.rport % 1 ~= 0 then
        return false, "invalid remote port"
    end

    -- source selection
    local src
    if address.isLoopback(raddr) then
        src = LOOPBACK_ADDR
    else
        local route = routeFor(raddr)
        local iface = route and ifaces[route.iface] or nil
        if iface == nil then
            return false, "no route to host"
        end
        if iface.addr == nil then
            return false, "interface " .. tostring(route.iface) .. " has no address"
        end
        src = iface.addr
    end

    local sent, err = tcp.connect(sock, raddr, args.rport, src,
        advertisedMss(src, raddr), {
            pid = msg.pid,
            reqId = msg.id,
            deadline = now() + const.TCP_CONNECT_TIMEOUT,
        }, now())
    if sent == nil then
        return false, err
    end
    return nil
end

local function opTcpAccept(msg, args)
    if type(args.socketId) ~= "number" then
        return false, "socketId required"
    end
    local sock = tcp.get(args.socketId)
    if sock == nil then
        return false, "no such socket"
    end
    if sock.owner ~= msg.pid then
        return false, "not the socket owner"
    end
    if sock.state ~= "LISTEN" then
        return false, "not listening"
    end

    local child = tcp.popAccept(sock)
    if child then
        return true, {
            socketId = child.id,
            addr = address.dotted(child.laddr),
            port = child.lport,
            raddr = address.dotted(child.raddr),
            rport = child.rport,
        }
    end
    if sock.acceptWaiter then
        return false, "already waiting"
    end
    tcp.setAcceptWaiter(sock, { pid = msg.pid, reqId = msg.id })
    return nil -- deferred
end

local function opTcpAcceptCancel(msg, args)
    if type(args.socketId) ~= "number" then
        return false, "socketId required"
    end
    local sock = tcp.get(args.socketId)
    if sock == nil then
        return true, {}
    end
    if sock.owner ~= msg.pid then
        return false, "not the socket owner"
    end
    tcp.cancelAcceptWaiter(sock, args.reqId)
    return true, {}
end

local function opTcpSend(msg, args)
    if type(args.socketId) ~= "number" then
        return false, "socketId required"
    end
    local sock = tcp.get(args.socketId)
    if sock == nil then
        return false, "no such socket"
    end
    if sock.owner ~= msg.pid then
        return false, "not the socket owner"
    end
    if type(args.data) ~= "string" then
        return false, "data must be a string"
    end
    local ok, err = tcp.send(sock, args.data)
    if not ok then
        return false, err
    end
    return true, {}
end

local function opTcpRecv(msg, args)
    if type(args.socketId) ~= "number" then
        return false, "socketId required"
    end
    local sock = tcp.get(args.socketId)
    if sock == nil then
        return false, "no such socket"
    end
    if sock.owner ~= msg.pid then
        return false, "not the socket owner"
    end

    local entry = tcp.shiftQueue(sock)
    if entry == nil then
        if sock.eof then
            return false, "closed"
        end
        if sock.waiter then
            return false, "already waiting"
        end
        tcp.setWaiter(sock, { pid = msg.pid, reqId = msg.id })
        return nil -- deferred
    end
    return true, {
        data = entry,
        from = address.dotted(sock.raddr),
        port = sock.rport,
    }
end

local function opTcpRecvCancel(msg, args)
    if type(args.socketId) ~= "number" then
        return false, "socketId required"
    end
    local sock = tcp.get(args.socketId)
    if sock == nil then
        return true, {} -- nothing to cancel
    end
    if sock.owner ~= msg.pid then
        return false, "not the socket owner"
    end
    tcp.cancelWaiter(sock, args.reqId)
    return true, {}
end

local function opTcpClose(msg, args)
    if type(args.socketId) ~= "number" then
        return false, "socketId required"
    end
    local sock = tcp.get(args.socketId)
    if sock == nil then
        return true, {}
    end
    if sock.owner ~= msg.pid then
        return false, "not the socket owner"
    end
    local result, err = tcp.close(sock, {
        pid = msg.pid,
        reqId = msg.id,
        deadline = now() + const.TCP_CLOSE_TIMEOUT,
    }, now())
    if result == "deferred" then
        return nil
    end
    if result == nil then
        return false, err
    end
    debugLog("tcp close id=" .. tostring(args.socketId))
    return true, {}
end

-- This is very large
local ops = {
    ["interfaces"]        = opInterfaces,
    ["ifup"]              = opIfup,
    ["ifdown"]            = opIfdown,
    ["routes"]            = opRoutes,
    ["route_add"]         = opRouteAdd,
    ["route_del"]         = opRouteDel,
    ["arp"]               = opArp,
    ["arp_flush"]         = opArpFlush,
    ["sockets"]           = opSockets,
    ["reload"]            = opReload,
    ["udp_bind"]          = opUdpBind,
    ["udp_connect"]       = opUdpConnect,
    ["udp_send"]          = opUdpSend,
    ["udp_recv"]          = opUdpRecv,
    ["udp_recv_cancel"]   = opUdpRecvCancel,
    ["udp_close"]         = opUdpClose,
    ["ping_request"]      = opPingRequest,
    ["tcp_bind"]          = opTcpBind,
    ["tcp_listen"]        = opTcpListen,
    ["tcp_connect"]       = opTcpConnect,
    ["tcp_accept"]        = opTcpAccept,
    ["tcp_accept_cancel"] = opTcpAcceptCancel,
    ["tcp_send"]          = opTcpSend,
    ["tcp_recv"]          = opTcpRecv,
    ["tcp_recv_cancel"]   = opTcpRecvCancel,
    ["tcp_close"]         = opTcpClose,
}

local function handleRequest(msg)
    if type(msg.op) ~= "string" then
        if msg.pid then
            replyTo(msg, false, "missing op")
        end
        return
    end
    local handler = ops[msg.op]
    if handler == nil then
        return replyTo(msg, false, "unknown op: " .. msg.op)
    end
    local ok, result, err = pcall(handler, msg, msg.args or {})
    if not ok then
        log("request " .. msg.op .. " handler error: " .. tostring(result))
        return replyTo(msg, false, "internal error")
    end
    if result == nil then
        return -- deferred (no reply now)
    end
    replyTo(msg, result, err)
end

-- One at a time
local function dispatch(msg)
    local kind = msg.kind

    if kind == "tick" then
        stackTick()
    elseif kind == "event" then
        local ev = msg.ev
        if ev == "modem_message" then
            local args = msg.args or {}
            ethernet.onModemMessage(table.unpack(args, 1, args.n or #args))
        elseif ev == "component_added" then
            if msg.ctype == "tunnel" then
                knownTunnels[msg.address] = true
            else
                knownModems[msg.address] = true
            end
            local iface = ifaceByHw(msg.address)
            if iface == nil then
                log((msg.ctype == "tunnel" and "linked card" or "modem") ..
                    " added: " .. tostring(msg.address))
                local conf = state.conf or {}
                local names = {}
                for name in pairs(conf.autos or {}) do
                    names[#names + 1] = name
                end
                table.sort(names)
                for _, name in ipairs(names) do
                    if ifaceByHw(msg.address) == nil and
                        not ifaces[name] and not adminDown[name]
                    then
                        -- only chase slot names of the same component kind
                        local slot
                        if msg.ctype == "tunnel" then
                            slot = lnkSlotNumber(name)
                        else
                            slot = ethSlotNumber(name)
                        end
                        if slot ~= nil or name == msg.address then
                            raise(name, (conf.ifaces or {})[name], msg.address)
                        end
                    end
                end
            end
        elseif ev == "component_removed" then
            if msg.ctype == "tunnel" then
                knownTunnels[msg.address] = nil
            else
                knownModems[msg.address] = nil
            end
            local iface = ifaceByHw(msg.address)
            if iface then
                log("modem removed: " .. tostring(msg.address) .. " (" .. iface.name .. ")")
                lower(iface.name)
                -- Hey wheres my modem at? Nvm found it
                if not ifaces[iface.name] then
                    adminDown[iface.name] = nil
                    lastRetryError[iface.name] = nil
                end
            end
        end
    elseif kind == "request" then
        handleRequest(msg)
    else
    end
end

local function mainLoop()
    local process = polaris.process
    while true do
        local msg = process.waitForInput()

        if not state.running then
            return "stopped"
        end

        if type(msg) == "string" and process.isSignal(msg) then
            -- yeah lets just go i
            return "signal " .. tostring(msg)
        end

        if type(msg) == "table" and msg.network then
            dispatch(msg)
        end
        coroutine.yield()
    end
end

local function raiseAutostart()
    if state.conf == nil then return end
    for _, errLine in ipairs(state.conf.errors or {}) do
        log("/etc/network/interfaces: " .. errLine)
    end
    for name in pairs(state.conf.autos) do
        if not ifaces[name] then
            local ok, err = raise(name, state.conf.ifaces[name])
            if not ok then
                log("ifup " .. name .. " failed: " .. tostring(err))
            end
        end
    end
end

function M.start()
    local process = polaris.process
    local okSelf, selfInfo = pcall(process.self)
    if not okSelf or type(selfInfo) ~= "table" or selfInfo.pid == nil then
        return nil, "knetd must run inside a process"
    end

    M.detach()

    state.pid = selfInfo.pid
    state.cfg = config.loadOptions(const.DEFAULTS)
    state.conf = config.loadInterfaces()

    createLoopbackIface()
    wireInjections()

    -- event listeners
    local ev = require("event")
    state.listeners.modem = ev.listen("modem_message", onModemMessageEvent)
    state.listeners.added = ev.listen("component_added", onComponentAdded)
    state.listeners.removed = ev.listen("component_removed", onComponentRemoved)
    state.listeners.tick = ev.timer(state.cfg.tick or const.DEFAULTS.tick, onTickTimer, math.huge)

    ipc.setDaemon(state.pid)
    raiseAutostart()

    state.running = true
    log("knetd started (pid " .. tostring(state.pid) .. ")")
    return true
end

function M.stop()
    state.running = false
    if state.pid then
        polaris.process.send(state.pid, { network = true, kind = "wake" })
    end
    return true
end

--Detach everything
function M.detach()
    local ev = require("event")
    for _, id in pairs(state.listeners) do
        if id then pcall(ev.cancel, id) end
    end
    state.listeners = {}

    ethernet.clear()
    arp.reset()
    ipv4.resetAll()
    icmp.reset()
    udp.reset()
    tcp.reset()

    ifaces = {}
    state.conf = nil
    state.running = false

    if state.pid then
        ipc.clearDaemon()
        log("knetd detached (pid " .. tostring(state.pid) .. ")")
        state.pid = nil
    end
    return true
end

function M.loop()
    if not state.running then
        return nil, "stack not started"
    end

    local ok, err = xpcall(mainLoop, function(errMsg)
        return debug.traceback(tostring(errMsg), 2)
    end)

    M.detach()

    if not ok then
        log("knetd crashed: " .. tostring(err))
        error(err, 0)
    end

    log("knetd stopped (" .. tostring(err) .. ")")
    return true
end

return M
