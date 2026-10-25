-- /usr/lib/network/admin.lua
-- RPC to knetd and some cool stuff

local const = require("network.const")
local ipc = require("network.ipc")

local M = {}

local CALL_TIMEOUT = const.DEFAULTS.requestTimeout

local function call(op, args, timeout)
    return ipc.call(op, args or {}, timeout or CALL_TIMEOUT)
end

-- Everything we know
function M.interfaces(timeout)
    local reply, err = call("interfaces", {}, timeout)
    if not reply then
        return nil, err
    end
    return reply.interfaces, nil
end

function M.ifup(name, timeout)
    local reply, err = call("ifup", { name = name }, timeout)
    if not reply then
        return nil, err
    end
    return true
end

function M.ifdown(name, timeout)
    local reply, err = call("ifdown", { name = name }, timeout)
    if not reply then
        return nil, err
    end
    return true
end

-- All routes we know
function M.routes(timeout)
    local reply, err = call("routes", {}, timeout)
    if not reply then
        return nil, err
    end
    return reply.routes, nil
end

function M.routeAdd(net, gateway, dev, metric, timeout)
    local reply, err = call("route_add", {
        net = net,
        via = gateway,
        dev = dev,
        metric = metric,
    }, timeout)
    if not reply then
        return nil, err
    end
    return reply.route, nil
end

function M.routeDel(spec, timeout)
    local reply, err = call("route_del", { route = spec }, timeout)
    if not reply then
        return nil, err
    end
    return true
end

function M.arp(timeout)
    local reply, err = call("arp", {}, timeout)
    if not reply then
        return nil, err
    end
    return reply.entries, nil
end

function M.arpFlush(timeout)
    local reply, err = call("arp_flush", {}, timeout)
    if not reply then
        return nil, err
    end
    return true
end

-- All open UDP sockets
function M.sockets(timeout)
    local reply, err = call("sockets", {}, timeout)
    if not reply then
        return nil, err
    end
    return reply.sockets, nil
end

-- All open TCP sockets
function M.tcpSockets(timeout)
    local reply, err = call("sockets", {}, timeout)
    if not reply then
        return nil, err
    end
    return reply.tcp, nil
end

function M.reload(timeout)
    local reply, err = call("reload", {}, timeout)
    if not reply then
        return nil, err
    end
    return true
end

-- Ping time
local function pingFilter(reqId)
    return function(value)
        if type(value) ~= "table" or not value.network then
            return false
        end
        if value.kind == "reply" and value.id == reqId then
            return true
        end
        if (value.kind == "notify" or value.kind == "data") and
            value.op == "ping" and value.id == reqId
        then
            return true
        end
        return false
    end
end

local function notifyFilter(reqId)
    return function(value)
        if type(value) ~= "table" or not value.network then
            return false
        end
        if (value.kind == "notify" or value.kind == "data") and
            value.op == "ping" and value.id == reqId
        then
            return true
        end
        return false
    end
end

-- Sends and waits
function M.ping(dst, icmpId, seq, payload, timeout)
    local daemon = ipc.getDaemon()
    if not daemon then
        return nil, "knetd not running"
    end

    local req = ipc.request("ping_request", {
        dst = dst,
        id = icmpId,
        seq = seq or 0,
        payload = payload or "",
        timeout = timeout or const.DEFAULTS.icmpTimeout,
    })
    local ok = ipc.send(daemon, req)
    if not ok then
        ipc.clearDaemon()
        return nil, "knetd not running"
    end

    local msg, err = ipc.wait(pingFilter(req.id), (timeout or const.DEFAULTS.icmpTimeout) + 1)

    if msg == nil then
        msg = ipc.wait(notifyFilter(req.id), 0.5)
        if msg == nil then
            return nil, err
        end
    end

    if msg.kind == "reply" then
        if not msg.ok then
            return nil, msg.err or "ping failed"
        end
        msg = ipc.wait(notifyFilter(req.id), (timeout or const.DEFAULTS.icmpTimeout) + 1)
        if msg == nil then
            return nil, "timeout"
        end
    end

    local result = {
        type = msg.type,
        dst = msg.dst,
        id = msg.icmpId,
        seq = msg.seq,
        payload = msg.payload,
    }
    return result, nil
end

return M
