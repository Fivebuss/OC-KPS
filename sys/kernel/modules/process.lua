--[[
Process module. Yeah its a connector between i/o and scheduler
And because the current handling of scheduler was weird
Plus it is helpful for signal stuff and when I add children and more signal stuff

Anyway it is a manager for scheduler + fd 0,1,2 
As such it copies alot and imports scheduler.
So userspace doesnt need to care about my aweful code :)




Functions of this
  process.spawn(fn, opts): opts = { onExit, label, ppid }. Returns pid
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
    INT  = "INT",
    KILL = "KILL",
    TSTP = "TSTP",
    CONT = "CONT",
    HUP  = "HUP",
}

-- This is weird but it syncs
local table_ = {}

-- [pid] = { [0]=stdin desc, [1]=stdout desc, [2]=stderr desc }
local processIO = {}

local function scheduler()
    return polaris.scheduler
end

-- Parent? Maybe
function process.spawn(fn, opts)
    checkArg(1, fn, "function")
    checkArg(2, opts, "table", "nil")
    opts = opts or {}

    local ppid = opts.ppid
    if ppid == nil then
        ppid = process.self()
    elseif ppid == false then
        ppid = nil
    end

    local pid = scheduler().spawn(fn, opts.onExit, opts.label)

    table_[pid] = {
        ppid = ppid,
        cmd = opts.label or "?",
        spawnedAt = scheduler().info(pid) and scheduler().info(pid).spawnedAt or 0,
    }

    return pid
end

-- PID of itself
function process.self()
    return scheduler().currentThread()
end

function process.exists(pid)
    return table_[pid] ~= nil
end

-- PS table info
function process.get(pid)
    local own = table_[pid]
    if not own then return nil end

    local info = scheduler().info(pid)
    if not info then
        -- scheduler forgot about it before we did somehow, yes this really happened during testing
        return {
            pid = pid,
            ppid = own.ppid,
            cmd = own.cmd,
            spawnedAt = own.spawnedAt,
        }
    end

    return {
        pid = pid,
        ppid = own.ppid,
        cmd = own.cmd,
        label = info.label,
        status = info.status,
        waiting = info.waiting,
        sleeping = info.sleeping,
        cancelled = info.cancelled,
        stopped = info.stopped,
        spawnedAt = info.spawnedAt,
        age = info.age,
    }
end

-- List PIDs
function process.list()
    local out = {}
    for pid in pairs(table_) do
        out[#out + 1] = process.get(pid)
    end
    return out
end

-- Scheduler forgets it
local function forget(pid)
    table_[pid] = nil
end

-- Exit the active process from inside
function process.exit(code)
    return scheduler().exit(code)
end

-- Kill
function process.kill(pid)
    local ok = scheduler().kill(pid)
    if ok then forget(pid) end
    return ok
end

function process.killAll(exceptPid)
    scheduler().killAll(exceptPid)
    for pid in pairs(table_) do
        if pid ~= exceptPid then forget(pid) end
    end
end

-- Ask nicely "please die"
function process.cancel(pid)
    return scheduler().cancel(pid)
end

function process.cancelAll()
    scheduler().cancelAll()
end

function process.isCancelled(pid)
    return scheduler().isCancelled(pid)
end

-- Check if it got told to die
function process.checkCancel()
    return scheduler().checkCancel()
end

-- Signal stuff

function process.signal(pid, sig)
    return scheduler().signal(pid, sig)
end

function process.signalAll(sig)
    return scheduler().signalAll(sig)
end

function process.pendingSignal(pid)
    return scheduler().pendingSignal(pid)
end

-- ^Z / fg
function process.stop(pid)
    return scheduler().stop(pid)
end

function process.cont(pid)
    return scheduler().cont(pid)
end

function process.isStopped(pid)
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
