-- /sys/kernel/modules/process.lua
--[[
Process module. Yeah its a connector between i/o and scheduler
And because the current handling of scheduler was weird
Plus it is helpful for signal stuff and when I add children and more signal stuff

Anyway it is a manager for scheduler + fd 0,1,2 
As such it copies alot and imports scheduler.
So userspace doesnt need to care about my aweful code :)

Child parent rules are freaky. Okay so:
Inherit groups
Inherit PPID
Usually kernel-owned if not chosen
SIGCHLD is just a signal sent to a parent
Can set a opts.onOrphaned to figure out if it's parent dies
If a parent dies the kernel owns it

Process groups are just custom because linux is freaky
  process.GROUP = {
    SYS     = 1, -- kernel lives here, you cannot touch it. Normally
    MISM    = 2, -- "mismanaged" yeah this is helpful for me, see below
    SYSRESV = {3,4,5}, -- system reserved reserved
    USER    = 6, -- default group for anything unless it specifies one
    USERFG  = 7,
    USERBG  = 8,
  }
  9+ is custom defined and needs setpgid syscall
  About mismanaged:
  If a group is told to die and one process is stubborn it gets assigned here
  Yes this is useful I swear. No but really, it is as the kernel can try ways to force it to die
  And great for debugging i/o




Functions of this
  process.spawn(fn, opts): opts = { onExit, label, ppid, pgid, onOrphaned }. Returns pid
  process.self(): pid of the currently running process, or nil
  process.exists(pid): Does it?
  process.get(pid): copy of that processs table entry, or nil
  process.list(): copy of the whole process table ps style
  process.exit(code): exit the CURRENT process
  process.kill(pid): Kills a process without asking
  process.cancel(pid) / process.cancelAll(): ask nicely for one to die
  process.isCancelled(pid) / process.checkCancel(): checks if TERM
  process.signal(pid, sig) / process.signalAll(sig): SIG.* spam
  process.pendingSignal(pid)
  process.stop(pid) / process.cont(pid) / process.isStopped(pid): ^Z
  process.SIG: scheduler.SIG

  process.children(pid): list of pids parented to pid right now
  process.parent(pid): ppid, or kernel pid if orphaned/none
  process.getGroup(pid) / process.setGroup(pid, gid) / process.setGroupPriv(pid, gid, token)
  process.groupMembers(gid) / process.killGroup(gid) / process.signalGroup(gid, sig)
  process.reapGroup(gid): group-kill survivors into MISM
  process.GROUP: group id constants

  process.sleep(seconds)
  process.waitForInput(): Waits for input
  process.send(pid, value): wake a process blocked in waitForInput

  process.create(pid, stdin, stdout, stderr) / process.destroy(pid)
  process.stream(fd, file) / process.input/output/error(file)
  process.write(...) / process.writeError(...)
  process.closeAll(pid)
  process.describe(pid)
--]]

local io = require("sys.kernel.modules.io")

local process = {}

process.SIG = {
    INT   = "INT",
    KILL  = "KILL",
    TSTP  = "TSTP",
    CONT  = "CONT",
    HUP   = "HUP",
    CHLD  = "CHLD", -- Yes I know not a handler bite me 
}

-- omg process groups
process.GROUP = {
    SYS     = 1,
    MISM    = 2,
    -- 3,4,5 = sysresv reserved
    USER    = 6,
    USERFG  = 7,
    USERBG  = 8,
}

local SYSRESV = { [3] = true, [4] = true, [5] = true }
local DEFAULT_GROUP = process.GROUP.USER
local MAX_UNPRIV_GROUP = process.GROUP.USERBG -- 8; 9+ needs the priv path

-- This is weird but it syncs
local table_ = {}

-- [pid] = { [0]=stdin desc, [1]=stdout desc, [2]=stderr desc }
local processIO = {}

-- [gid] = { [pid] = true }
local groups = {}

-- pids mid-group kill
-- [gid] = { [pid] = true }
local pendingGroupKill = {}

local function scheduler()
    return polaris.scheduler
end

-- Show the kernel 
local kernelRegistered = false

local function isKernelPid(pid)
    return pid ~= nil and pid == scheduler().kernelProcess
end

local function isKernel()
    if kernelRegistered then return end

    local kpid = scheduler().kernelProcess
    if not kpid then return end

    table_[kpid] = {
        ppid = "bootloader",
        cmd = "kernel",
        pgid = process.GROUP.SYS,
        children = {},
        onOrphaned = nil,
        spawnedAt = scheduler().info(kpid) and scheduler().info(kpid).spawnedAt or 0,
    }
    groups[process.GROUP.SYS] = groups[process.GROUP.SYS] or {}
    groups[process.GROUP.SYS][kpid] = true

    kernelRegistered = true
end

-- Makes sure its a sane PGID. no, you cannot set it to -1
local function normalizeGroup(gid)
    if type(gid) ~= "number" then return process.GROUP.SYS end
    if gid == process.GROUP.SYS then return process.GROUP.SYS end
    if SYSRESV[gid] then return process.GROUP.SYS end
    if gid < 1 then return process.GROUP.SYS end
    if gid > MAX_UNPRIV_GROUP then return process.GROUP.SYS end
    return gid
end

local function addToGroup(pid, gid)
    groups[gid] = groups[gid] or {}
    groups[gid][pid] = true
end

local function removeFromGroup(pid, gid)
    if groups[gid] then
        groups[gid][pid] = nil
    end
end

-- If a child dies
local function reparentToKernel(pid)
    local entry = table_[pid]
    if not entry then return end

    local kpid = scheduler().kernelProcess
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

    if entry.pgid then
        removeFromGroup(pid, entry.pgid)
    end
end

-- Parent? Maybe
function process.spawn(fn, opts)
    checkArg(1, fn, "function")
    checkArg(2, opts, "table", "nil")
    opts = opts or {}

    local selfPid = process.self()
    local hadActiveParent = (opts.ppid == nil) and (selfPid ~= nil)

    local ppid = opts.ppid
    if ppid == nil then
        ppid = selfPid
    elseif ppid == false then
        ppid = nil
    end

    if ppid == nil then
        isKernel()
        ppid = scheduler().kernelProcess
    end

    -- Look at top for rules for this once I write them
    local pgid
    if opts.pgid ~= nil then
        pgid = normalizeGroup(opts.pgid)
    elseif hadActiveParent then
        local parentEntry = table_[ppid]
        pgid = (parentEntry and parentEntry.pgid) or DEFAULT_GROUP
    else
        pgid = DEFAULT_GROUP
    end

    local pid -- I fixed it I think
    pid = scheduler().spawn(fn, function(success, reason, ...)
        onProcessDeath(pid)
        if opts.onExit then
            opts.onExit(success, reason, ...)
        end
        -- Scheduler forgot it so did we 
        table_[pid] = nil
    end, opts.label)

    table_[pid] = {
        ppid = ppid,
        pgid = pgid,
        cmd = opts.label or "?",
        children = {},
        onOrphaned = opts.onOrphaned,
        spawnedAt = scheduler().info(pid) and scheduler().info(pid).spawnedAt or 0,
    }

    if ppid and table_[ppid] then
        table_[ppid].children = table_[ppid].children or {}
        table_[ppid].children[pid] = true
    end

    addToGroup(pid, pgid)

    return pid
end

-- PID of itself
function process.self()
    return scheduler().currentThread()
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

    local info = scheduler().info(pid)
    if not info then
        -- scheduler forgot about it before we did somehow, yes this really happened during testing
        return {
            pid = pid,
            ppid = own.ppid,
            pgid = own.pgid,
            cmd = own.cmd,
            spawnedAt = own.spawnedAt,
            protected = isKernelPid(pid),
        }
    end

    return {
        pid = pid,
        ppid = own.ppid,
        pgid = own.pgid,
        cmd = own.cmd,
        label = info.label,
        status = info.status,
        waiting = info.waiting,
        sleeping = info.sleeping,
        cancelled = info.cancelled,
        stopped = info.stopped,
        spawnedAt = info.spawnedAt,
        age = info.age,
        protected = isKernelPid(pid),
    }
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
    if entry and entry.pgid then
        removeFromGroup(pid, entry.pgid)
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
    return entry.ppid or scheduler().kernelProcess
end

-- Groups

-- I wonder what this does
function process.getGroup(pid)
    isKernel()
    local entry = table_[pid]
    return entry and entry.pgid or nil
end

-- Members
function process.groupMembers(gid)
    isKernel()
    local g = groups[gid]
    if not g then return {} end

    local out = {}
    for pid in pairs(g) do
        if table_[pid] then
            out[#out + 1] = pid
        end
    end
    return out
end

-- Does grid stuff
function process.setGroup(pid, gid)
    if isKernelPid(pid) then return false end
    local entry = table_[pid]
    if not entry then return false end

    local newGid = normalizeGroup(gid)

    if entry.pgid then
        removeFromGroup(pid, entry.pgid)
    end
    entry.pgid = newGid
    addToGroup(pid, newGid)

    return true, newGid
end

-- A syscall handles this
function process.setGroupPriv(pid, gid)
    if isKernelPid(pid) then return false end

    local entry = table_[pid]
    if not entry then return false end

    checkArg(2, gid, "number")
    if gid < 1 then return false, "invalid gid" end
    if SYSRESV[gid] then return false, "gid reserved" end

    if entry.pgid then
        removeFromGroup(pid, entry.pgid)
    end
    entry.pgid = gid
    addToGroup(pid, gid)

    return true, gid
end

-- Signal every member
function process.signalGroup(gid, sig)
    isKernel()
    if gid == process.GROUP.SYS then return 0 end -- Stop trying to kill the kernel, for loop

    local count = 0
    for pid in pairs(groups[gid] or {}) do
        if table_[pid] and not isKernelPid(pid) then
            process.signal(pid, sig)
            count = count + 1
        end
    end

    if sig == process.SIG.KILL then
        -- Who did we try to kill?
        pendingGroupKill[gid] = pendingGroupKill[gid] or {}
        for pid in pairs(groups[gid] or {}) do
            if table_[pid] and not isKernelPid(pid) then
                pendingGroupKill[gid][pid] = true
            end
        end
    end

    return count
end

-- Kill every member without asking
function process.killGroup(gid)
    isKernel()
    if gid == process.GROUP.SYS then return 0 end

    pendingGroupKill[gid] = pendingGroupKill[gid] or {}

    local count = 0
    for pid in pairs(groups[gid] or {}) do
        if not isKernelPid(pid) then
            pendingGroupKill[gid][pid] = true
            if process.kill(pid) then
                count = count + 1
            end
        end
    end

    return count
end

-- MISM, it can happen at a weird time of course
function process.reapGroup(gid)
    isKernel()
    local pending = pendingGroupKill[gid]
    if not pending then return {} end

    local survivors = {}
    for pid in pairs(pending) do
        if table_[pid] and table_[pid].pgid == gid then
            -- It refused to die
            process.setGroup(pid, process.GROUP.MISM)
            survivors[#survivors + 1] = pid
        end
    end

    pendingGroupKill[gid] = nil
    return survivors
end

-- Exit the active process from inside
function process.exit(code)
    if isKernelPid(process.self()) then return false end
    return scheduler().exit(code)
end

function process.kill(pid)
    if isKernelPid(pid) then return false end
    return scheduler().kill(pid)
end

function process.killAll(exceptPid)
    isKernel()

    local kpid = scheduler().kernelProcess
    local except = exceptPid
    if except == nil then except = kpid end

    -- Reparent all at once
    scheduler().killAll(except)

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
    return scheduler().cancel(pid)
end

function process.cancelAll()
    isKernel()

    local kpid = scheduler().kernelProcess
    for pid in pairs(table_) do
        if pid ~= kpid then
            scheduler().cancel(pid)
        end
    end
end

function process.isCancelled(pid)
    if isKernelPid(pid) then return false end
    return scheduler().isCancelled(pid)
end

-- Check if it got told to die
function process.checkCancel()
    if isKernelPid(process.self()) then return end
    return scheduler().checkCancel()
end

-- Signal stuff

function process.signal(pid, sig)
    if isKernelPid(pid) then return false end
    return scheduler().signal(pid, sig)
end

function process.signalAll(sig)
    isKernel()

    local kpid = scheduler().kernelProcess
    for pid in pairs(table_) do
        if pid ~= kpid then
            scheduler().signal(pid, sig)
        end
    end
end

function process.pendingSignal(pid)
    if isKernelPid(pid) then return nil end
    return scheduler().pendingSignal(pid)
end

-- ^Z / fg
function process.stop(pid)
    if isKernelPid(pid) then return false end
    return scheduler().stop(pid)
end

function process.cont(pid)
    if isKernelPid(pid) then return false end
    return scheduler().cont(pid)
end

function process.isStopped(pid)
    if isKernelPid(pid) then return false end
    return scheduler().isStopped(pid)
end

-- Other

function process.sleep(seconds)
    return scheduler().sleep(seconds)
end

function process.waitForInput()    -- Used alot less
    return scheduler().waitForInput()
end

-- Wake a process that is blocked
function process.send(pid, value)
    return scheduler().sendData(pid, value)
end

process.sendData = process.send
process.currentThread = process.self

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

-- Obliterates fully
function process.destroy(pid)
    if isKernelPid(pid) then return false end

    process.closeAll(pid)
    processIO[pid] = nil
    forget(pid)
end

local function currentIO()
    local pid = process.self()
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