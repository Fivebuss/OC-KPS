-- /lib/network/socket/udp.lua
-- Hopefully works with process stuff

local const = require("network.const")
local ipc = require("network.ipc")
local address = require("network.address")

local M = {}

local DEFAULT_CALL_TIMEOUT = const.DEFAULTS.requestTimeout

function M.new()
    return {}
end

-- Handle table : { id, addr, port, raddr, rport }
function M.info(sock)
    if type(sock) ~= "table" or sock.id == nil then
        return nil
    end
    return {
        id = sock.id,
        addr = sock.addr,
        port = sock.port,
        raddr = sock.raddr,
        rport = sock.rport,
    }
end

function M.getsockname(sock)
    if type(sock) ~= "table" then return nil end
    return sock.addr, sock.port
end

function M.getpeername(sock)
    if type(sock) ~= "table" then return nil end
    return sock.raddr, sock.rport
end

function M.settimeout(sock, seconds)
    sock.timeout = seconds
    return true
end

function M.bind(sock, addr, port, timeout)
    local reply, err = ipc.call("udp_bind", {
        laddr = addr,
        lport = port,
    }, timeout or DEFAULT_CALL_TIMEOUT)
    if not reply then
        return nil, err
    end
    sock.id = reply.socketId
    sock.addr = reply.addr
    sock.port = reply.port
    return reply.addr, reply.port
end

-- This just sets the remote thing
function M.connect(sock, addr, port, timeout)
    if type(sock) ~= "table" or sock.id == nil then
        return nil, "socket not bound"
    end
    local reply, err = ipc.call("udp_connect", {
        socketId = sock.id,
        raddr = addr,
        rport = port,
    }, timeout or DEFAULT_CALL_TIMEOUT)
    if not reply then
        return nil, err
    end
    sock.raddr = reply.raddr
    sock.rport = reply.rport
    return reply.raddr, reply.rport
end

-- Please work
function M.send(sock, data, timeout)
    return M.sendto(sock, data, nil, nil, timeout)
end

function M.sendto(sock, data, addr, port, timeout)
    if type(sock) ~= "table" or sock.id == nil then
        return nil, "socket not bound"
    end
    if type(data) ~= "string" then
        return nil, "data must be a string"
    end
    if addr == nil then
        addr = sock.raddr
        port = sock.rport
    end
    if addr == nil then
        return nil, "not connected"
    end
    local dstAddr = addr
    if type(dstAddr) == "number" then
        dstAddr = address.dotted(dstAddr)
    end
    local reply, err = ipc.call("udp_send", {
        socketId = sock.id,
        data = data,
        addr = dstAddr,
        port = port,
    }, timeout or DEFAULT_CALL_TIMEOUT)
    if not reply then
        return nil, err
    end
    return true
end

-- Filter recv stuff
local function receiveFilter(sock, req)
    return function(value)
        if type(value) ~= "table" or not value.network then
            return false
        end
        if value.kind == "reply" and value.id == req.id then
            return true
        end
        if value.kind == "data" and value.ref == sock.id then
            return true
        end
        return false
    end
end

-- from-address problems
function M.recvfrom(sock, timeout)
    if type(sock) ~= "table" or sock.id == nil then
        return nil, "socket not bound"
    end

    local daemon = ipc.getDaemon()
    if not daemon then
        return nil, "knetd not running"
    end

    local req = ipc.request("udp_recv", { socketId = sock.id })
    local ok = ipc.send(daemon, req)
    if not ok then
        ipc.clearDaemon()
        return nil, "knetd not running"
    end

    local waitTimeout = timeout
    if waitTimeout == nil then
        waitTimeout = sock.timeout
    end

    local value, err = ipc.wait(receiveFilter(sock, req), waitTimeout)

    if value == nil then
        -- tell the daemon to forget about it
        local daemon2 = ipc.getDaemon()
        if daemon2 then
            local cancel = ipc.request("udp_recv_cancel", {
                socketId = sock.id,
                reqId = req.id,
            })
            ipc.send(daemon2, cancel)
        end
        return nil, err
    end

    if value.kind == "data" then
        return value.data, address.dotted(value.from), value.port, nil
    end

    if not value.ok then
        return nil, value.err or "receive failed", nil
    end
    return value.data, address.dotted(value.from), value.port, nil
end

M.receive = M.recvfrom

function M.recv(sock, timeout)
    local data, from, port, err = M.recvfrom(sock, timeout)
    return data, from, port, err
end

-- Dont do this more than once please
function M.close(sock, timeout)
    if type(sock) ~= "table" or sock.id == nil then
        return nil, "socket not bound"
    end
    local reply, err = ipc.call("udp_close", { socketId = sock.id },
        timeout or DEFAULT_CALL_TIMEOUT)
    sock.id = nil
    sock.addr = nil
    sock.port = nil
    sock.raddr = nil
    sock.rport = nil
    if not reply then
        return nil, err
    end
    return true
end

return M
