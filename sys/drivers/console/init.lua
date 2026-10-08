-- /sys/drivers/console/init.lua

-- Console driver time!
-- I HATE MULTI GPU. But its soooo cool to not include

local event = require("event")
local component = require("component")

local console = {}
local gpus = {}
local screenMap = {}
local ttyRegistry = {}

local function getKeyboards(screen_addr)
    local ok, result = pcall(component.invoke, screen_addr, "getKeyboards")
    if not ok or type(result) ~= "table" then return {} end
    local set = {}
    for _, kb in ipairs(result) do set[kb] = true end
    return set
end

local function bindGpu(gpu_addr, screen_addr)
    local proxy = component.proxy(gpu_addr)
    proxy.bind(screen_addr)
    local w, h = proxy.maxResolution()
    proxy.setResolution(w, h)
    local entry            = {
        proxy     = proxy,
        screen    = screen_addr,
        keyboards = getKeyboards(screen_addr),
        ttys      = {},
    }
    gpus[gpu_addr]         = entry
    screenMap[screen_addr] = gpu_addr
    return entry
end

local function unbindGpu(gpu_addr)
    local entry = gpus[gpu_addr]
    if not entry then return end
    for tty in pairs(entry.ttys) do
        pcall(tty.close, tty)
    end
    screenMap[entry.screen] = nil
    gpus[gpu_addr] = nil
end

local function scanHardware()
    for screen_addr in component.list("screen", true) do
        for gpu_addr in component.list("gpu", true) do
            if not gpus[gpu_addr] then
                bindGpu(gpu_addr, screen_addr)
                break
            end
        end
    end
end

-- This is hilariously broken, but I may(?) add a hotplug thing for spawning or removing shells when they can?
-- ...but that would need a login shell and like just no not right now
event.listen("component_added", function(_, addr, kind)
    if kind == "screen" then
        for gpu_addr in component.list("gpu", true) do
            if not gpus[gpu_addr] then
                bindGpu(gpu_addr, addr)
                break
            end
        end
    elseif kind == "gpu" then
        for screen_addr in component.list("screen", true) do
            if not screenMap[screen_addr] then
                bindGpu(addr, screen_addr)
                break
            end
        end
    elseif kind == "keyboard" then
        for screen_addr, gpu_addr in pairs(screenMap) do
            local entry = gpus[gpu_addr]
            if entry then
                entry.keyboards = getKeyboards(screen_addr)
            end
        end
    end
end)

event.listen("component_removed", function(_, addr, kind)
    if kind == "gpu" then
        unbindGpu(addr)
    elseif kind == "screen" then
        local gpu_addr = screenMap[addr]
        if gpu_addr then unbindGpu(gpu_addr) end
    elseif kind == "keyboard" then
        for screen_addr, gpu_addr in pairs(screenMap) do
            local entry = gpus[gpu_addr]
            if entry then
                entry.keyboards[addr] = nil
            end
        end
    end
end)

-- I hijack the proxy. Yes, proxy^2
local function makeGpuProxy(gpu_entry)
    local valid = true
    local proxy = setmetatable({}, {
        __index = function(_, k)
            if not valid then error("console: GPU no longer available") end
            return gpu_entry.proxy[k]
        end,
        __newindex = function() error("console: gpu proxy is read-only") end,
    })
    return proxy, function() valid = false end
end

-- console.openTTY(opts) gives tty, err
--
-- opts.gpu   = gpu_addr (nil = first available gpu)
-- opts.owner = pid
function console.openTTY(opts)
    opts = opts or {}

    local entry
    if opts.gpu then
        entry = gpus[opts.gpu]
        if not entry then
            return nil, "console: GPU not managed: " .. tostring(opts.gpu)
        end
    else
        for _, e in pairs(gpus) do
            entry = e; break
        end
        if not entry then return nil, "console: no GPU available" end
    end

    local gpuProxy, invalidate = makeGpuProxy(entry)
    local ttyObj = polaris.tty.new(gpuProxy)

    -- Now dont ask but overriding events here is because I cannot be arsed to tell tty "hey use this keyboard"
    -- its simpler anyway lol

    event.cancel(ttyObj.keyHandlerId)

    ttyObj.keyHandlerId = event.register(nil, function(sig, kb_addr, a, b)
        if not entry.keyboards[kb_addr] then return end
        if sig == "key_down" then
            ttyObj:onKeyDown(a, b)
        elseif sig == "clipboard" then
            ttyObj:clipboard(a)
        end
    end, math.huge, math.huge)

    local _attach = ttyObj.attach
    local _detach = ttyObj.detach
    local attached = {}

    -- current ttys gpu
    local gpu_addr
    for addr, e in pairs(gpus) do
        if e == entry then
            gpu_addr = addr; break
        end
    end

    function ttyObj:attach(pid)
        if attached[pid] then
            return nil, "console: pid " .. tostring(pid) .. " already attached"
        end
        attached[pid] = true
        polaris.process.setCtty(pid, gpu_addr)
        return _attach(self, pid)
    end

    function ttyObj:detach(pid)
        attached[pid] = nil
        polaris.process.clearCtty(pid)
        return _detach(self, pid)
    end

    function ttyObj:isAttached(pid)
        return attached[pid] == true
    end

    local _close = ttyObj.close
    function ttyObj:close()
        entry.ttys[self] = nil
        ttyRegistry[self] = nil
        attached = {}
        invalidate()
        return _close(self)
    end

    ttyRegistry[ttyObj] = { entry = entry, invalidate = invalidate, owner = opts.owner }
    entry.ttys[ttyObj]  = true

    return ttyObj
end

function console.gpu(addr)
    if addr then return gpus[addr] and gpus[addr].proxy end
    for _, e in pairs(gpus) do return e.proxy end
end

function console.gpus()
    local t = {}
    for addr, e in pairs(gpus) do t[addr] = e.proxy end
    return pairs(t)
end

-- console.getInfo() is just a table of useful info
-- thank AI for this doc, il be nice
-- {
--   gpus = {
--     [gpu_addr] = {
--       screen    = screen_addr,
--       keyboards = { kb_addr, ... },
--       ttys      = {
--         [n] = {
--           attached  = { pid, ... },
--           owner     = pid_or_nil,
--           cx, cy    = write cursor position,
--           w, h      = dimensions,
--         }
--       }
--     }
--   }
-- }
function console.getInfo()
    local info = { gpus = {} }
    for gpu_addr, entry in pairs(gpus) do
        local kbs = {}
        for kb in pairs(entry.keyboards) do kbs[#kbs + 1] = kb end
        table.sort(kbs)

        local ttyList = {}
        for ttyObj in pairs(entry.ttys) do
            local meta = ttyRegistry[ttyObj]
            local pids = {}
            for pid in pairs(ttyObj.attachedUids or {}) do
                pids[#pids + 1] = pid
            end
            table.sort(pids)
            ttyList[#ttyList + 1] = {
                owner    = meta and meta.owner,
                attached = pids,
                cx       = ttyObj.cx,
                cy       = ttyObj.cy,
                w        = ttyObj.w,
                h        = ttyObj.h,
            }
        end

        info.gpus[gpu_addr] = {
            screen    = entry.screen,
            keyboards = kbs,
            ttys      = ttyList,
        }
    end
    return info
end

scanHardware()

return console
