-- /sys/drivers/console/init.lua

-- Console driver time!
-- I HATE MULTI GPU. But its soooo cool to not include

local event = require("event")
local component = require("component")

local devfs = polaris.devfs

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

-- Naming them
local function next_tty_name()
    local used = {}
    for _, meta in pairs(ttyRegistry) do
        local n = tonumber(meta.name:match("^tty(%d+)$"))
        if n then used[n] = true end
    end
    local n = 0
    while used[n] do n = n + 1 end
    return "tty" .. n
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
    devfs.bump()
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
-- ...but that would need a login shell and like just no not right now. Whats that? login shell exists? Still no.
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
    local ttyObj = polaris.tty.new(gpuProxy, entry.keyboards)

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
        local meta = ttyRegistry[self]
        if meta then meta.alive = false end
        entry.ttys[self] = nil
        ttyRegistry[self] = nil
        attached = {}
        invalidate()
        devfs.bump()
        return _close(self)
    end

    ttyRegistry[ttyObj] = {
        name       = next_tty_name(),
        owner      = opts.owner,
        gpu        = gpu_addr,
        entry      = entry,
        invalidate = invalidate,
        alive      = true,
    }
    entry.ttys[ttyObj]  = true
    devfs.bump()

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

function console.tys()
    local list = {}
    for ttyObj, meta in pairs(ttyRegistry) do
        list[#list + 1] = { name = meta.name, tty = ttyObj }
    end
    table.sort(list, function(a, b)
        return tonumber(a.name:match("%d+")) < tonumber(b.name:match("%d+"))
    end)
    return list
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

function console.setResolution(w, h)
    local ok = false
    for _, entry in pairs(gpus) do
        if entry.proxy.setResolution(w, h) then
            for ttyObj in pairs(entry.ttys) do
                pcall(ttyObj.setResolution, ttyObj, w, h)
            end
            ok = true
        end
    end
    return ok
end

-- /dev/tty
local function ttyFaces(ttyObj, meta)
    local faces = {
        tty = {
            open = function(mode)
                mode = mode or "r"
                local bRead = mode:match("[ra]")
                local bWrite = mode:match("[wa]")
                if not (bRead or bWrite) then
                    return nil, "invalid mode"
                end
                local handle = { close = function() return true end }
                if bRead then
                    handle.read = function(_, n)
                        return ttyObj.reader:read(n)
                    end
                end
                if bWrite then
                    handle.write = function(_, value)
                        if not meta.alive then return nil, "device lost" end
                        return ttyObj:write(tostring(value))
                    end
                end
                return handle
            end
        },
        attributes = {
            read = function()
                local a = ttyObj.attributes
                local ok, w, h = pcall(meta.entry.proxy.getResolution)
                if not ok then w, h = 0, 0 end
                return table.concat({
                    "echo=" .. tostring(a.echo),
                    "line=" .. tostring(a.line),
                    "raw=" .. tostring(a.raw),
                    "cursor=" .. tostring(a.cursor),
                    "xoff=" .. tostring(a.xoff),
                    "resolution=" .. tostring(w) .. "x" .. tostring(h),
                }, " ")
            end,
            write = function(input)
                for token in tostring(input or ""):gmatch("[^,%s]+") do
                    local key, value = token:match("^([^=]+)=(.*)$")
                    if key == "resolution" then
                        local w, h = value:match("^(%d+)x(%d+)$")
                        if not w or not h then
                            return nil, "invalid resolution: " .. tostring(value)
                        end
                        if not console.setResolution(tonumber(w), tonumber(h)) then
                            return nil, "failed to set resolution"
                        end
                    elseif not key or ttyObj.attributes[key] == nil then
                        return nil, "invalid attribute setting: " .. token
                    else
                        local on = value == "true" or value == "1" or value == "on"
                        local off = value == "false" or value == "0" or value == "off"
                        if not on and not off then
                            return nil, "invalid attribute setting: " .. token
                        end
                        ttyObj.attributes[key] = on
                    end
                end
            end,
        },
        signal = {
            write = function(input)
                local name = (tostring(input or ""):gsub("%s", "")):upper()
                local code = ({ INT = 3, TSTP = 26, KILL = 28 })[name]
                if not code then return nil, "unknown signal" end
                ttyObj:onKeyDown(code)
            end,
        },
        info = {
            read = function()
                if not meta.alive or not gpus[meta.gpu] then return nil, "device lost" end
                local ok, w, h = pcall(meta.entry.proxy.getResolution)
                if not ok then return nil, "device lost" end
                local pids = {}
                for pid in pairs(ttyObj.attachedUids or {}) do
                    pids[#pids + 1] = tostring(pid)
                end
                table.sort(pids)
                return table.concat({
                    "gpu " .. tostring(meta.gpu),
                    "screen " .. tostring(meta.entry.screen),
                    "resolution " .. tostring(w) .. "x" .. tostring(h),
                    "pids " .. (#pids > 0 and table.concat(pids, ",") or "-"),
                }, "\n")
            end,
        },
    }
    for _, face in pairs(faces) do
        if type(face.read) == "function" then face.read = devfs.prepare(face.read) end
        if type(face.write) == "function" then face.write = devfs.prepare(face.write) end
    end
    return faces
end

devfs.define("tty", function()
    local faces = {}
    for _, item in ipairs(console.tys()) do
        local ttyObj = item.tty
        faces[item.name] = { list = function()
            local meta = ttyRegistry[ttyObj]
            if not meta then return {} end
            return ttyFaces(ttyObj, meta)
        end }
    end
    return faces
end)

scanHardware()
polaris.analytics.addEvent("console")

return console
