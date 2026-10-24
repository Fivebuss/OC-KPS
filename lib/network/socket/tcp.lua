-- /lib/network/socket/tcp.lua
-- TCP time

local const = require("network.const")
local ipc = require("network.ipc")
local address = require("network.address")

local M = {}
local DEFAULT_CALL_TIMEOUT = const.DEFAULTS.requestTimeout

function M.new()
    return {}
end

-- info table: { id, addr, port, raddr, rport }
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

-- nil is just forever
function M.settimeout(sock, seconds)
    sock.timeout = seconds
    return true
end

function M.bind(sock, addr, port, timeout)
    local reply, err = ipc.call("tcp_bind", {
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

-- accept says hello
function M.listen(sock, addr, port, timeout)
    local reply, err = ipc.call("tcp_listen", {
        laddr = addr,
        lport = port,
    }, timeout or DEFAULT_CALL_TIMEOUT)
    if not reply then
        return nil, err
    end
    sock.id = reply.socketId
    sock.addr = reply.addr
    sock.port = reply.port
    sock.listening = true
    return reply.addr, reply.port
end

-- Blocking!
function M.connect(sock, addr, port, timeout)
    if type(sock) ~= "table" or sock.id == nil then
        return nil, "socket not bound"
    end
    local dstAddr = addr
    if type(dstAddr) == "number" then
        dstAddr = address.dotted(dstAddr)
    end
    local reply, err = ipc.call("tcp_connect", {
        socketId = sock.id,
        raddr = dstAddr,
        rport = port,
    }, (timeout or const.TCP_CONNECT_TIMEOUT) + 1)
    if not reply then
        return nil, err
    end
    sock.raddr = reply.raddr
    sock.rport = reply.rport
    return reply.raddr, reply.rport
end

-- Go wait
function M.accept(sock, timeout)
    if type(sock) ~= "table" or sock.id == nil then
        return nil, "socket not bound"
    end

    local daemon = ipc.getDaemon()
    if not daemon then
        return nil, "knetd not running"
    end

    local req = ipc.request("tcp_accept", { socketId = sock.id })
    local ok = ipc.send(daemon, req)
    if not ok then
        ipc.clearDaemon()
        return nil, "knetd not running"
    end

    local value, err = ipc.wait(function(value)
        return type(value) == "table" and value.network and
            value.kind == "reply" and value.id == req.id
    end, timeout)

    if value == nil then
        -- tell knetd to forget about it
        local daemon2 = ipc.getDaemon()
        if daemon2 then
            ipc.send(daemon2, ipc.request("tcp_accept_cancel", {
                socketId = sock.id,
                reqId = req.id,
            }))
        end
        return nil, err
    end
    if not value.ok then
        return nil, value.err or "accept failed"
    end
    return {
        id = value.socketId,
        addr = value.addr,
        port = value.port,
        raddr = value.raddr,
        rport = value.rport,
    }, nil
end

function M.send(sock, data, timeout)
    if type(sock) ~= "table" or sock.id == nil then
        return nil, "socket not bound"
    end
    if type(data) ~= "string" then
        return nil, "data must be a string"
    end
    local reply, err = ipc.call("tcp_send", {
        socketId = sock.id,
        data = data,
    }, timeout or DEFAULT_CALL_TIMEOUT)
    if not reply then
        return nil, err
    end
    return true
end

-- Filters based on recv
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
        if value.kind == "notify" and value.op == "tcp" and
            value.ref == sock.id and value.id == req.id
        then
            return true
        end
        return false
    end
end

-- from-address is used
function M.recvfrom(sock, timeout)
    if type(sock) ~= "table" or sock.id == nil then
        return nil, "socket not bound"
    end

    local daemon = ipc.getDaemon()
    if not daemon then
        return nil, "knetd not running"
    end

    local req = ipc.request("tcp_recv", { socketId = sock.id })
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
        local daemon2 = ipc.getDaemon()
        if daemon2 then
            local cancel = ipc.request("tcp_recv_cancel", {
                socketId = sock.id,
                reqId = req.id,
            })
            ipc.send(daemon2, cancel)
        end
        return nil, err
    end

    if value.kind == "data" then
        return value.data, value.from, value.port, nil
    end

    if value.kind == "notify" then
        if value.type == "closed" then
            return nil, "closed"
        end
        return nil, value.type == "timeout" and "timeout" or "connection reset"
    end

    if not value.ok then
        return nil, value.err or "receive failed"
    end
    return value.data, value.from, value.port, nil
end

M.receive = M.recvfrom

function M.recv(sock, timeout)
    local data, _, _, err = M.recvfrom(sock, timeout)
    return data, err
end

function M.close(sock, timeout)
    if type(sock) ~= "table" or sock.id == nil then
        return nil, "socket not bound"
    end
    local reply, err = ipc.call("tcp_close", { socketId = sock.id },
        (timeout or const.TCP_CLOSE_TIMEOUT) + 1)
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
