-- /lib/network/const.lua
-- Daemon and libraries both use this

local M               = {}

-- L2
M.ETHER_PORT          = 51

M.ETHER_TYPES         = {
    IPv4 = 0x0800,
    ARP  = 0x0806,
    RARP = 0x8035,
    IPv6 = 0x86DD,
}

-- IP protocol numbers
M.PROTOCOLS           = {
    ICMP = 1,
    TCP  = 6,
    UDP  = 17,
}

-- Dont bind to this
M.CONTROL_ADDRESS     = "127.0.0.1"
M.CONTROL_PORT        = 49374

M.MAC_BROADCAST       = "ffffffff-ffff-ffff-ffff-ffffffffffff"

-- The modem addresses
M.HTYPE_ETHERNET      = 1

M.EPHEMERAL_PORT_MIN  = 49152
M.EPHEMERAL_PORT_MAX  = 65535

M.ARP_QUEUE_MAX       = 16
M.UDP_QUEUE_MAX       = 64
M.FRAG_BUFFER_MAX     = 64

-- TCP
M.TCP_WINDOW          = 8192 -- advertised receive window, bytes
M.TCP_MSS_FALLBACK    = 1240 -- segment cap when no interface MTU is known
M.TCP_QUEUE_MAX       = 64  -- per-socket receive/accept queue entries
M.TCP_RTO             = 1   -- base retransmission timeout, seconds
M.TCP_RETRIES         = 5   -- retransmits before a connection resets
M.TCP_TIME_WAIT       = 5   -- TIME_WAIT hold, seconds (the RFC says 240)
M.TCP_CONNECT_TIMEOUT = 5   -- handshake deadline, seconds
M.TCP_CLOSE_TIMEOUT   = 5   -- graceful close deadline, seconds

-- Default options
M.DEFAULTS            = {
    tick           = 0.25, -- seconds between stack ticks
    debug          = false,
    mtu            = 1280, -- fallback interface MTU (ethernet payload bytes)
    arpTimeout     = 1,    -- seconds between ARP request retries
    arpRetries     = 3,
    arpExpire      = 300,  -- seconds a resolved ARP entry stays valid
    fragTimeout    = 10,   -- seconds before a partial IPv4 reassembly drops
    icmpTimeout    = 5,    -- default ping deadline
    requestTimeout = 5,    -- default client-side control request deadline
}

return M
