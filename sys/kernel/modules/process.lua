-- /sys/kernel/modules/process.lua
--[[
Process module. Yeah its a connector between i/o and scheduler
And because the current handling of scheduler was weird

It also sets up fd 0,1,2
So userspace doesnt need to care about my aweful scheduler internals :)

Child parent rules are freaky. Okay so:
Inherit groups
Inherit PPID
Usually kernel-owned if not chosen
SIGCHLD is just a signal sent to a parent
If a parent dies the kernel owns it

Groups are different from linux, they are pretty self explanatory except:
SVC/service, kernel is here. It IS a service after all due to syscalls
MISM exists due to weird coroutine state stuff:
If it refuses to die it is moved here
idk how it could even end up here without OC GC killing it but whatever
However weird process stuff can cause it

--]]

local scheduler = polaris.scheduler
local io = require("io")

local process = {}

process.SIG = {
    INT   = "INT",
    KILL  = "KILL",
    TSTP  = "TSTP",
    CONT  = "CONT",
    HUP   = "HUP",
    CHLD  = "CHLD", -- Yes I know not a handler bite me

    [1]  = "HUP",
    [2]  = "INT",
    [9]  = "KILL",
    [17] = "CHLD",
    [18] = "CONT",
    [20] = "TSTP",
}

-- omg process groups, but per-user this time
process.GID = {
    SVC  = 1, -- services + kernel if uid 0
    USER = 2, -- default
    FG   = 3,
    BG   = 4,
    MISM = 5, -- "mismanaged" see above
}

local GIDSET = {}
for _, v in pairs(process.GID) do
    GIDSET[v] = true
end

local KERNEL_UID = 0
local DEFAULT_GID = process.GID.USER
local MAX_UNPRIV_GID = process.GID.MISM -- 6-8 unused

-- This is weird but it syncs
local table_ = {}

-- [pid] = { [0]=stdin desc, [1]=stdout desc, [2]=stderr desc }
local processIO = {}

-- [uid] = { [gid] = { [pid] = true } }
local groups = {}

local pendingGroupKill = {}

-- Kernel
local kernelRegistered = false

local function isKernelPid(pid)
    return pid ~= nil and pid == scheduler.kernelProcess
end

local function isKernel()
    if kernelRegistered then return end

    local kpid = scheduler.kernelProcess
    if not kpid then return end

    table_[kpid] = {
        ppid = "bootloader",
        cmd = "kernel",
        uid = KERNEL_UID,
        gid = process.GID.SVC,
        children = {},
        onOrphaned = nil,
        spawnedAt = scheduler.info(kpid) and scheduler.info(kpid).spawnedAt or 0,
    }

    groups[KERNEL_UID] = groups[KERNEL_UID] or {}
    groups[KERNEL_UID][process.GID.SVC] = groups[KERNEL_UID][process.GID.SVC] or {}
    groups[KERNEL_UID][process.GID.SVC][kpid] = true

    kernelRegistered = true
end

-- Makes sure its a sane GID
local function normalizeGid(gid)
    if type(gid) ~= "number" then return nil end
    if GIDSET[gid] then return gid end
    return nil
end

local function normalizeUid(uid)
    if type(uid) ~= "number" then return nil end
    if uid < 0 or uid % 1 ~= 0 then return nil end
    return uid
end

local function groupTree(uid, gid)
    groups[uid] = groups[uid] or {}
    groups[uid][gid] = groups[uid][gid] or {}
    return groups[uid][gid]
end

local function addToGroup(pid, uid, gid)
    groupTree(uid, gid)[pid] = true
end

local function removeFromGroup(pid, uid, gid)
    local u = groups[uid]
    if u and u[gid] then
        u[gid][pid] = nil
    end
end

-- If a child dies
local function reparentToKernel(pid)
    local entry = table_[pid]
    if not entry then return end

    local kpid = scheduler.kernelProcess
    isKernel()

    if entry.onOrphaned then
        -- Hope
        pcall(entry.onOrphaned, entry.ppid)
    end

    entry.ppid = kpid
    if kpid and table_[kpid] then
        table_[kpid].children = table_[kpid].children or {}
        table_[kpid].children[pid] = true
    end
end

-- does reparenting and SIGCHLD
local function onProcessDeath(pid)
    local entry = table_[pid]
    if not entry then return end

    -- Sorry to hear the news
    if entry.ppid and entry.ppid ~= pid and table_[entry.ppid] then
        process.signal(entry.ppid, process.SIG.CHLD)
        local pchildren = table_[entry.ppid].children
        if pchildren then pchildren[pid] = nil end
    end

    -- Orphan our own children to the kernel
    if entry.children then
        for childPid in pairs(entry.children) do
            reparentToKernel(childPid)
        end
    end

    removeFromGroup(pid, entry.uid, entry.gid)
end

--[[ spawn opts:
    label
    onExit function
    ppid, parent process id, or set to false to be kernel owned
    uid, defaults to self or kernel
    gid, one of process.GID. inherits from parent if same uid,
        else SVC for uid 0 and USER for everyone else
    onOrphaned function
--]]
function process.spawn(fn, opts)
    checkArg(1, fn, "function")
    checkArg(2, opts, "table", "nil")
    opts = opts or {}

    local caller = scheduler.activeThread()
    --local hadActiveParent = (opts.ppid == nil) and (caller ~= nil)

    local ppid = opts.ppid
    if ppid == nil then
        ppid = caller
    elseif ppid == false then
        ppid = nil
    end

    if ppid == nil then
        isKernel()
        ppid = scheduler.kernelProcess
    end

    local parentEntry = ppid and table_[ppid] or nil

    -- Get from the guy who does this, or its kernel. Or set.
    local uid
    if opts.uid ~= nil then
        uid = normalizeUid(opts.uid)
        if not uid then
            error("process.spawn: invalid uid", 2)
        end
    elseif caller and table_[caller] then
        uid = table_[caller].uid
    else
        uid = KERNEL_UID
    end

    -- Inherits GID from parent! Or SVC if kernel does it
    local gid
    if opts.gid ~= nil then
        gid = normalizeGid(opts.gid)
        if not gid then
            error("process.spawn: invalid gid (see process.GID)", 2)
        end
    elseif parentEntry and parentEntry.uid == uid then
        gid = parentEntry.gid or DEFAULT_GID
    elseif caller and table_[caller] and table_[caller].uid == uid then
        gid = table_[caller].gid or DEFAULT_GID
    else
        gid = DEFAULT_GID
    end

    local pid -- I fixed it I think
    pid = scheduler.spawn(fn, function(success, reason, ...)
        onProcessDeath(pid)
        if opts.onExit then
            opts.onExit(success, reason, ...)
        end
        -- Scheduler forgot it so did we
        table_[pid] = nil
    end, opts.label)

    table_[pid] = {
        ppid = ppid,
        uid = uid,
        gid = gid,
        cmd = opts.cmd or opts.label or "?",
        children = {},
        onOrphaned = opts.onOrphaned,
        spawnedAt = scheduler.info(pid) and scheduler.info(pid).spawnedAt or 0,
    }

    if ppid and table_[ppid] then
        table_[ppid].children = table_[ppid].children or {}
        table_[ppid].children[pid] = true
    end

    addToGroup(pid, uid, gid)

    return pid
end

-- Actually gives useful info about self
function process.self()
    local pid = scheduler.activeThread()
    if not pid then return nil end
    return process.get(pid)
end

-- if you are lazy
function process.activeThread()
    return scheduler.activeThread()
end

function process.exists(pid)
    isKernel()
    return table_[pid] ~= nil
end

-- PS table info
function process.get(pid)
    isKernel()

    local own = table_[pid]
    if not own then return nil end

    local info = scheduler.info(pid)
    local base = {
        pid = pid,
        ppid = own.ppid,
        uid = own.uid,
        gid = own.gid,
        cmd = own.cmd,
        spawnedAt = own.spawnedAt,
        protected = isKernelPid(pid),
        ctty = own.ctty,
    }

    if not info then
        -- scheduler forgot about it before we did somehow, yes this really happened during testing
        return base
    end

    base.label = info.label
    base.status = info.status
    base.waiting = info.waiting
    base.sleeping = info.sleeping
    base.cancelled = info.cancelled
    base.stopped = info.stopped
    base.age = info.age
    return base
end

-- List PIDs
function process.list()
    isKernel()

    local out = {}
    for pid in pairs(table_) do
        out[#out + 1] = process.get(pid)
    end
    return out
end

-- Scheduler forgets it
local function forget(pid)
    local entry = table_[pid]
    if entry then
        removeFromGroup(pid, entry.uid, entry.gid)
    end
    table_[pid] = nil
end

-- Oh boy.

-- Children of a pid
function process.children(pid)
    isKernel()
    local entry = table_[pid]
    if not entry or not entry.children then return {} end

    local out = {}
    for childPid in pairs(entry.children) do
        if table_[childPid] then
            out[#out + 1] = childPid
        end
    end
    return out
end

-- ppid or kernel
function process.parent(pid)
    isKernel()
    local entry = table_[pid]
    if not entry then return nil end
    return entry.ppid or scheduler.kernelProcess
end

-- UID stuff
function process.getUID(pid)
    isKernel()
    local entry = table_[pid]
    return entry and entry.uid or nil
end

-- Moves a PID to a UID
function process.setUID(pid, uid)
    if isKernelPid(pid) then return false end

    local entry = table_[pid]
    if not entry then return false end

    local newUid = normalizeUid(uid)
    if not newUid then return false, "invalid uid" end

    if newUid == entry.uid then return true, newUid end

    removeFromGroup(pid, entry.uid, entry.gid)
    entry.uid = newUid

    addToGroup(pid, entry.uid, entry.gid)

    return true, entry.gid
end

-- Groups

-- Just the gid
function process.getGroup(pid)
    isKernel()
    local entry = table_[pid]
    return entry and entry.gid or nil
end

function process.getGroups(pid)
    isKernel()
    local entry = table_[pid]
    if not entry then return nil end
    return entry.uid, entry.gid
end

-- Members of a (uid, gid) group
function process.groupMembers(uid, gid)
    isKernel()
    local u = groups[uid]
    local g = u and u[gid]
    if not g then return {} end

    local out = {}
    for pid in pairs(g) do
        if table_[pid] then
            out[#out + 1] = pid
        end
    end
    return out
end

-- Does gid stuff
function process.setGroup(pid, gid)
    if isKernelPid(pid) then return false end
    local entry = table_[pid]
    if not entry then return false end

    local newGid = normalizeGid(gid)
    if not newGid then return false, "invalid gid" end

    removeFromGroup(pid, entry.uid, entry.gid)
    entry.gid = newGid
    addToGroup(pid, entry.uid, newGid)

    return true, newGid
end

-- Custom groups. Why seperated? To test out negative shenanigans, thats it. Useless for general user
function process.setGroupPriv(pid, gid)
    if isKernelPid(pid) then return false end

    local entry = table_[pid]
    if not entry then return false end

    checkArg(2, gid, "number")
    if gid <= MAX_UNPRIV_GID then return false, "gid reserved" end

    removeFromGroup(pid, entry.uid, entry.gid)
    entry.gid = gid
    addToGroup(pid, entry.uid, gid)

    return true, gid
end

-- Signal every member of a (uid, gid)
function process.signalGroup(uid, gid, sig)
    isKernel()

    local count = 0
    for pid in pairs(groupTree(uid, gid)) do
        if table_[pid] and not isKernelPid(pid) then
            process.signal(pid, sig)
            count = count + 1
        end
    end

    if sig == process.SIG.KILL then
        -- Who did we try to kill?
        if not pendingGroupKill[uid] then pendingGroupKill[uid] = {} end
        local pending = pendingGroupKill[uid][gid]
        if not pending then
            pending = {}
            pendingGroupKill[uid][gid] = pending
        end
        for pid in pairs(groups[uid][gid] or {}) do
            if table_[pid] and not isKernelPid(pid) then
                pending[pid] = true
            end
        end
    end

    return count
end

-- Kill every member without asking
function process.killGroup(uid, gid)
    isKernel()

    if not pendingGroupKill[uid] then pendingGroupKill[uid] = {} end
    local pending = pendingGroupKill[uid][gid]
    if not pending then
        pending = {}
        pendingGroupKill[uid][gid] = pending
    end

    local count = 0
    for pid in pairs(groups[uid] and groups[uid][gid] or {}) do
        if not isKernelPid(pid) then
            pending[pid] = true
            if process.kill(pid) then
                count = count + 1
            end
        end
    end

    return count
end

-- MISM, it can happen at a weird time of course
function process.reapGroup(uid, gid)
    isKernel()
    local pending = pendingGroupKill[uid] and pendingGroupKill[uid][gid]
    if not pending then return {} end

    local survivors = {}
    for pid in pairs(pending) do
        local entry = table_[pid]
        if entry and entry.uid == uid and entry.gid == gid then
            -- It refused to die
            process.setGroup(pid, process.GID.MISM)
            survivors[#survivors + 1] = pid
        end
    end

    pendingGroupKill[uid][gid] = nil
    return survivors
end

-- Exit the active process from inside
function process.exit(code)
    if isKernelPid(scheduler.activeThread()) then return false end
    return scheduler.exit(code)
end

function process.kill(pid)
    if isKernelPid(pid) then return false end
    return scheduler.kill(pid)
end

function process.killAll(exceptPid)
    isKernel()

    local kpid = scheduler.kernelProcess
    local except = exceptPid
    if except == nil then except = kpid end

    -- Reparent all at once
    scheduler.killAll(except)

    -- I hope this wont be reachable
    for pid in pairs(table_) do
        if pid ~= except and not isKernelPid(pid) then
            forget(pid)
        end
    end
end

-- Ask nicely "please die"
function process.cancel(pid)
    if isKernelPid(pid) then return false end
    return scheduler.cancel(pid)
end

function process.cancelAll()
    isKernel()

    local kpid = scheduler.kernelProcess
    for pid in pairs(table_) do
        if pid ~= kpid then
            scheduler.cancel(pid)
        end
    end
end

function process.isCancelled(pid)
    if isKernelPid(pid) then return false end
    return scheduler.isCancelled(pid)
end

-- Signal stuff

function process.signal(pid, sig)
    if isKernelPid(pid) then return false end
    return scheduler.signal(pid, sig)
end

function process.signalAll(sig)
    isKernel()

    local kpid = scheduler.kernelProcess
    for pid in pairs(table_) do
        if pid ~= kpid then
            scheduler.signal(pid, sig)
        end
    end
end

function process.pendingSignal(pid)
    if isKernelPid(pid) then return nil end
    return scheduler.pendingSignal(pid)
end

function process.isSignal(...)
    return scheduler.isSignal(...)
end

-- Yields an extra tick! Exists to keep signals arriving
function process.yield()
    -- Okay fine one more tick
    scheduler.yield()
    return true
end

-- ^Z / fg
function process.stop(pid)
    if isKernelPid(pid) then return false end
    return scheduler.stop(pid)
end

function process.cont(pid)
    if isKernelPid(pid) then return false end
    return scheduler.cont(pid)
end

function process.isStopped(pid)
    if isKernelPid(pid) then return false end
    return scheduler.isStopped(pid)
end

-- Other

function process.sleep(seconds)
    return scheduler.sleep(seconds)
end

function process.waitForInput()    -- Used alot less
    return scheduler.waitForInput()
end

-- Wake a process that is blocked
function process.send(pid, value)
    return scheduler.sendData(pid, value)
end

process.sendData = process.send

-- now the i/o side

-- stdin/stdout/stderr are raw streams abd stdin is fully buffered, stdout
-- and stderr are line-buffered
function process.create(pid, stdin, stdout, stderr)
    checkArg(1, pid, "number")

    processIO[pid] = {
        [0] = io.newDescriptor(polaris.buffer.new("r", stdin)),
        [1] = io.newDescriptor(io.newLineBuffered(polaris.buffer.new("w", stdout))),
        [2] = io.newDescriptor(io.newLineBuffered(polaris.buffer.new("w", stderr))),
    }
end

-- Closes fd 0/1/2 for pid without forgetting the entry
function process.closeAll(pid)
    if isKernelPid(pid) then return false end

    local t = processIO[pid]
    if not t then return end

    for fd = 0, 2 do
        local desc = t[fd]
        if desc then
            desc:release()
            t[fd] = nil
        end
    end
end

-- Obliterates running, io and forgets a pid
function process.destroy(pid)
    if isKernelPid(pid) then return false end

    process.closeAll(pid)
    processIO[pid] = nil
    forget(pid)
end

local function currentIO()
    local pid = scheduler.activeThread()
    if not pid then
        error("process: must be used from within a running process", 2)
    end

    local t = processIO[pid]
    if not t then
        error("process: no fd table for current process (pid " .. tostring(pid) .. ")", 2)
    end

    return t
end

local function checkFd(fd)
    if type(fd) ~= "number" then
        error("bad argument #1 (number expected, got " .. type(fd) .. ")", 3)
    end

    assert(fd == 0 or fd == 1 or fd == 2, "fd must be 0 (stdin), 1 (stdout), or 2 (stderr)")
end

-- Get (or replace) a stream on current
function process.stream(fd, file)
    checkFd(fd)

    local t = currentIO()

    if file then
        local newDesc = io.isDescriptor(file) and file or io.newDescriptor(file)
        local old = t[fd]
        t[fd] = newDesc

        if old then
            old:release()
        end
    end

    return t[fd]
end

function process.input(file)
    return process.stream(0, file)
end

function process.output(file)
    return process.stream(1, file)
end

function process.error(file)
    return process.stream(2, file)
end

function process.write(...)
    return process.output():write(...)
end

function process.writeError(...)
    return process.error():write(...)
end

-- Just a table entry for what tty is being used
function process.setCtty(pid, gpu_addr)
    local entry = table_[pid]
    if not entry then return false end
    entry.ctty = gpu_addr
    return true
end

function process.clearCtty(pid)
    local entry = table_[pid]
    if not entry then return false end
    entry.ctty = nil
    return true
end

-- fd tables
function process.describe(pid)
    local fds = processIO[pid]
    if not fds then return nil end

    return {
        [0] = io.describeStream(fds[0]),
        [1] = io.describeStream(fds[1]),
        [2] = io.describeStream(fds[2]),
    }
end

return process