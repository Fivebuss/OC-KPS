--[[
/lib/network/init.lua
The main network library stuff

local network = require("network")
local sock = network.udp.new()
network.udp.bind(sock, "127.0.0.1", 0)
network.udp.sendto(sock, "hi", "127.0.0.1", 9000)
local data, from, port = network.udp.recvfrom(sock, 5)
network.udp.close(sock)
]]--

local const = require("network.const")
local websocket = require("network.address")
local ipc = require("network.ipc")
local config = require("network.config")
local admin = require("network.admin")
local udp = require("network.socket.udp")
local tcp = require("network.socket.tcp")

local M = {
    const = const,
    address = websocket,
    ipc = ipc,
    config = config,
    admin = admin,
    udp = udp,
    tcp = tcp,
    control = {
        address = const.CONTROL_ADDRESS,
        port = const.CONTROL_PORT,
    },
}

--Is knetd alive right now?
function M.isRunning()
    return M.ipc.getDaemon() ~= nil
end

function M.newId()
    return M.ipc.newId()
end

return M
