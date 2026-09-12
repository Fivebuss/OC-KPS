-- A bad lua scheduler I wrote like 3 showers ago
-- Ported from MShell lol

--[[

Lsched
Cooperative multitasking. Kinda
How I use it:

scheduler.spawn(func, onExit): returns uid (I hope)
scheduler.sleep(seconds): Sleep that still in the end just yields, but we do it fancy. WHERE IS MY SLEEP() LUA! C should not be needed!
scheduler.waitForInput(): returns value ; Call inside a spawned coroutine! Blocks until sendData(uid, value) is used then returns
scheduler.sendData(uid, value): returns boolean ; gives a value to a blocked thread, so we can communicate "hey go do something"
scheduler.currentThread(): returns uid or null; gives the uid of the current thread, of course
scheduler.activeThread(): returns uid of actively executing thread, callable outside
scheduler.isBusy: returns boolean ; Whether anything is doing stuff
scheduler.init(event, tickInterval): Registers a handle. Do this once

-- Cancellation --
scheduler.kill(uid): Makes a corountine die without telling it
scheduler.cancel(uid): Tells a corountine "hey you can die"
scheduler.isCancelled(uid): returns boolean ; check from inside a corountine
scheduler.checkCancel(): call with no args from inside a spawned coroutine. If cancel() was requested, it yields "cancelled" back to the tick loop, which then treats it exactly like a normal return
scheduler.killAll(): Forcibly kills all corountines
scheduler.cancellAll(): Sends a signal to all corountines its time to die


--]]

local computer = require("computer")
local scheduler = {}
local handlers = {}

scheduler.SIG = {
    INT  = "INT",  -- Ctrl+C, thread can choose to exit or not
    KILL = "KILL", -- Ctrl+/, forces it to die
    TSTP = "TSTP", -- CTRL Z
    CONT = "CONT", -- Continued
    HUP  = "HUP",  -- Ctrl+D / hangup, kinda?
}

local threads = {}
local threadCount = 0
local activeUid = nil
local nextUid = 0

local coroutine_resume = coroutine.resume
local coroutine_create = coroutine.create
local coroutine_yield = coroutine.yield
local coroutine_status = coroutine.status
local computer_uptime = computer.uptime

-- Fancy
function scheduler.sleep(seconds)
    checkArg(1, seconds, "number")
    coroutine_yield("sleep", seconds)
end

function scheduler.waitForInput()
    return coroutine_yield("readInput")
end

-- Returns the uid of your own thread from inside
function scheduler.currentThread()
    local running = coroutine.running()

    for uid, t in pairs(threads) do
        if t.co == running then
            return uid
        end
    end

    return nil
end

-- Walkie talkie
function scheduler.sendData(uid, value)
    local t = threads[uid]
    if not t then
        return false
    end

    -- I need this bad
    t.inputQueue = t.inputQueue or {}
    table.insert(t.inputQueue, value)

    if t.waiting then
        t.waiting = false
        t.hasResume = true
        t.resumeVal = table.remove(t.inputQueue, 1)
        t.wakeAt = nil
    end
    return true
end

-- "proper" Signals
function scheduler.signal(uid, sig)
    local t = threads[uid]
    if not t then return false end

    t.pendingSignal = sig

    if sig == scheduler.SIG.KILL then
        return scheduler.kill(uid)
    end

    t.cancelled = true
    if t.wakeAt ~= nil then t.wakeAt = 0 end
    if t.waiting then
        t.waiting = false
        t.hasResume = true
        t.resumeVal = nil
    end
    return true
end

function scheduler.signalAll(sig)
    local uids = {}
    for uid in pairs(threads) do table.insert(uids, uid) end
    for _, uid in ipairs(uids) do scheduler.signal(uid, sig) end
end

function scheduler.pendingSignal(uid)
    local t = threads[uid or activeUid]
    return t and t.pendingSignal or nil
end

-- onExit is a bit jank I think
function scheduler.spawn(fn, onExit, label)
    checkArg(1, fn, "function")
    checkArg(2, onExit, "function", "nil")
    checkArg(3, label, "string", "nil")

    nextUid = nextUid + 1
    local uid = nextUid

    threads[uid] = {
        co = coroutine_create(fn),
        wakeAt = nil,
        waiting = false,
        hasResume = false,
        resumeVal = nil,
        onExit = onExit,
        cancelled = false,
        exiting = false,
        exitCode = nil,
        pendingSignal = nil,
        label = label or "?",
        spawnedAt = computer_uptime(),
    }
    threadCount = threadCount + 1

    return uid
end

function scheduler.isBusy()
    return threadCount > 0
end

function scheduler.threadCount()
    return threadCount
end

-- Copy of active coroutines
function scheduler.list()
    local out = {}
    local now = computer_uptime()
    for uid, t in pairs(threads) do
        out[#out + 1] = {
            uid = uid,
            label = t.label or "?",
            status = coroutine_status(t.co), -- "suspended", "running", "normal", "dead"
            waiting = t.waiting or false,    -- blocked in waitForInput
            sleeping = t.wakeAt ~= nil,      -- blocked in scheduler.sleep()
            cancelled = t.cancelled or false,
            stopped = t.stopped or false,
            spawnedAt = t.spawnedAt or 0,
            age = now - (t.spawnedAt or now),
        }
    end
    return out
end

-- Look up info by a id
function scheduler.info(uid)
    local t = threads[uid]
    if not t then return nil end
    local now = computer_uptime()
    return {
        uid = uid,
        label = t.label or "?",
        status = coroutine_status(t.co),
        waiting = t.waiting or false,
        sleeping = t.wakeAt ~= nil,
        cancelled = t.cancelled or false,
        stopped = t.stopped or false,
        spawnedAt = t.spawnedAt or 0,
        age = now - (t.spawnedAt or now),
    }
end

-- CTRL Z
function scheduler.stop(uid)
    local t = threads[uid]
    if not t or t.stopped then return false end

    t.stopped = true
    t.pendingSignal = scheduler.SIG.TSTP

    if t.wakeAt ~= nil then
        t.sleepRemaining = math.max(0, t.wakeAt - computer_uptime())
        t.wakeAt = nil
    end
    return true
end

-- Continue normally
function scheduler.cont(uid)
    local t = threads[uid]
    if not t or not t.stopped then return false end

    t.stopped = false
    t.pendingSignal = scheduler.SIG.CONT

    if t.sleepRemaining ~= nil then
        t.wakeAt = computer_uptime() + t.sleepRemaining
        t.sleepRemaining = nil
    end
    return true
end

function scheduler.isStopped(uid)
    local t = threads[uid or activeUid]
    return t ~= nil and t.stopped or false
end

-- Makes a corountine die
function scheduler.kill(uid)
    local t = threads[uid]
    if not t then
        return false
    end

    threads[uid] = nil
    threadCount = threadCount - 1

    -- Cant exactly do this
    if t.onExit then
        t.onExit(false, "killed")
    end

    return true
end

-- Tells a corountine to die
function scheduler.cancel(uid)
    local t = threads[uid]
    if not t or t.cancelled then
        return false
    end

    t.cancelled = true

    -- Wake up!
    if t.wakeAt ~= nil then
        t.wakeAt = 0
    end

    -- Unblock input
    if t.waiting then
        t.waiting = false
        t.hasResume = true
        t.resumeVal = nil
    end

    return true
end

-- Exit codes
function scheduler.exit(code)
    checkArg(1, code, "number", "nil")
    if code == nil or code < 0 or code > 255 then
        code = 0
    end

    local uid = activeUid
    local t = threads[uid]

    if not t or t.exiting then
        return false
    end

    t.exiting = true
    t.exitCode = code

    -- Wake up if sleeping
    if t.wakeAt ~= nil then
        t.wakeAt = 0
    end

    -- Unblock input
    if t.waiting then
        t.waiting = false
        t.hasResume = true
        t.resumeVal = nil
    end

    return true
end

-- Check cancellation flag for any uid
function scheduler.isCancelled(uid)
    local t = threads[uid or activeUid]
    return t ~= nil and t.cancelled or false
end

-- Exits without return (loops)
function scheduler.checkCancel()
    local uid = activeUid
    local t = threads[uid]
    if t and t.cancelled then
        error("cancelled", 0)
    end
end

-- Tells all corountines to go die
function scheduler.cancelAll()
    for uid in pairs(threads) do
        scheduler.cancel(uid)
    end
end

-- Kills all corountines
function scheduler.killAll(exceptUid)
    for uid in pairs(threads) do
        if uid ~= exceptUid then
            scheduler.kill(uid)
        end
    end
    if exceptUid then
        threads[exceptUid] = nil
        threadCount = threadCount - 1
        -- So we can exclude onExit
    end
end

-- Returns the UID of the corountine active
function scheduler.activeThread()
    return activeUid or nil
end

-- Cleans up all handlers
function scheduler.cleanup(event)
    for id, _ in pairs(handlers) do
        event.cancel(id)
    end
    handlers = {}
end

-- Kills off a handler
function scheduler.deinit(event, handlerId)
    if handlerId and handlers[handlerId] then
        event.cancel(handlerId)
        handlers[handlerId] = nil
    end
end

-- Tick
local function tick(...)
    local thr = threads

    if threadCount == 0 then return end
    local now = computer_uptime()

    -- Fix changing during tick. How did I even do that?
    local uids = {}
    for uid in pairs(thr) do
        table.insert(uids, uid)
    end

    for _, uid in ipairs(uids) do
        local t = thr[uid]
        if t and not t.waiting and not t.stopped then
            local ready = (t.wakeAt == nil) or (now >= t.wakeAt)
            if ready then
                activeUid = uid

                local ok, a, b, c
                if t.hasResume then
                    local v = t.resumeVal
                    t.hasResume = false
                    t.resumeVal = nil
                    ok, a, b, c = coroutine_resume(t.co, v)
                elseif t.wakeAt ~= nil then
                    ok, a, b, c = coroutine_resume(t.co)
                else
                    ok, a, b, c = coroutine_resume(t.co, ...)
                end

                activeUid = nil

                -- thread might have been killed by itself or another thread
                -- mid-resume
                if thr[uid] ~= t then
                    -- gone already, nothing more to do
                elseif t.exiting then
                    thr[uid] = nil
                    threadCount = threadCount - 1

                    if t.onExit then
                        t.onExit(true, t.exitCode)
                    end
                elseif not ok then
                    thr[uid] = nil
                    threadCount = threadCount - 1
                    if t.onExit then t.onExit(false, a) end
                elseif coroutine_status(t.co) == "dead" then
                    thr[uid] = nil
                    threadCount = threadCount - 1
                    if a == "cancelled" then
                        if t.onExit then t.onExit(true, "cancelled") end
                    else
                        if t.onExit then t.onExit(true, a, b, c) end
                    end
                else
                    -- Added read input for Mshell
                    local reason = a
                    if reason == "sleep" and type(b) == "number" then
                        t.wakeAt = computer.uptime() + b -- Hopefully be more accurate
                        t.waiting = false
                    elseif reason == "readInput" then
                        if t.inputQueue and #t.inputQueue > 0 then
                            t.hasResume = true
                            t.resumeVal = table.remove(t.inputQueue, 1)
                            t.waiting = false
                            t.wakeAt = nil
                        else
                            t.wakeAt = nil
                            t.waiting = true
                        end
                    else
                        t.wakeAt = nil
                        t.waiting = false
                    end
                end
            end
        end
    end
end

-- Starts it up
function scheduler.init(event, tickInterval)
    checkArg(1, event, "table")
    checkArg(2, tickInterval, "number", "nil")

    local interval = tickInterval or 0.1
    local handlerId = event.timer(interval, tick, math.huge)

    -- Allowing multiple (in theory)
    handlers[handlerId] = interval

    return handlerId
end

return scheduler
