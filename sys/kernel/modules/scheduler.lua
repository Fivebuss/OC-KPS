-- /sys/kernel/modules/scheduler.lua

-- Lsched v2
-- Ported from MShell and then I did some nonsense to it



--[[

Lsched
Cooperative multitasking. Kinda
Oh look, a bigass comment block. Thanks AI I am not typing all of it this time

scheduler.spawn(fn, onExit, label, handlers): returns uid
    handlers (optional): {
        INT  = function(sig, ...) end,
        CONT = function(sig, ...) end,
        HUP  = function(sig, ...) end,
        CHLD = function(childUid, ok, result, ...) end,
    }
    A custom handler REPLACES the default action for that signal.
    The signal is still delivered to the thread itself at its next
    yield point (see below). CHLD fires when a thread spawned by this
    thread dies. TSTP and KILL are always hard and cannot be intercepted.

Signals are delivered as resume values. Whatever the thread yielded --
scheduler.sleep(), scheduler.waitForInput(), or a plain coroutine.yield() --
comes back as the signal name ("INT", "HUP", "CHLD", ...) if a signal was
pending when the scheduler resumed it. Test with scheduler.isSignal(v).
Get the signal's arguments with scheduler.lastSignal().

Default actions (used when no handler is attached):
    INT / HUP : thread is cancelled and dies at its next yield, with a final resume for cleanup
    CHLD      : queued and delivered on the next resume; nothing is killed.
    CONT      : scheduler.cont(uid)
    TSTP      : hard stop (Ctrl+Z), not interceptable
    KILL      : hard kill, not interceptable

scheduler.sleep(seconds) -> sig|nil      (now returns a delivered signal, if any)
scheduler.waitForInput() -> value|sig    (a signal can preempt queued input)
scheduler.yield() -> sig|nil             sleep(0). cheap checkpoint, use in loops
scheduler.isSignal(v) -> boolean 
scheduler.lastSignal(uid) -> sig, ..
scheduler.sendData(uid, value) -> boolean
scheduler.activeThread() -> uid or nil
scheduler.isBusy() -> boolean
scheduler.threadCount() -> number
scheduler.list() / scheduler.info(uid)
scheduler.signal(uid, sig, ...) -> boolean
scheduler.signalAll(sig)
scheduler.pendingSignal(uid) -> sig|nil
scheduler.init(event, tickInterval) -> handlerId

-- Cancellation --
scheduler.kill(uid): Makes a coroutine die without telling it
scheduler.cancel(uid): Thread dies at its next yield
scheduler.isCancelled(uid): returns boolean
scheduler.killAll(exceptUid)
scheduler.cancelAll()


--]]

local computer = require("computer")
local event = require("sys.kernel.modules.event")
local scheduler = {}
local handlers = {}

local unpack = table.unpack or unpack

scheduler.SIG = {
    INT  = "INT",  -- Ctrl+C, thread can choose to exit or not (attach a handler)
    KILL = "KILL", -- Ctrl+/, forces it to die
    TSTP = "TSTP", -- CTRL Z
    CONT = "CONT", -- Continued
    HUP  = "HUP",  -- Ctrl+D / hangup
    CHLD = "CHLD", -- A child died
}

local SIGSET = {}
for _, v in pairs(scheduler.SIG) do
    SIGSET[v] = true
end

scheduler.sig = {}

local threads = {}
local threadCount = 0
local activeUid = nil
local nextUid = 0

-- Lets order stuff together
local order = {}
local orderCount = 0
local orderHoles = 0

-- Recycle pool for thread records
local pool = {}
local poolCount = 0
local MAX_POOL = 64

local coroutine_resume = coroutine.resume
local coroutine_create = coroutine.create
local coroutine_yield = coroutine.yield
local coroutine_status = coroutine.status
local computer_uptime = computer.uptime
local math_max = math.max
local math_huge = math.huge

-- Helpful stuff

-- Maybe this isnt slow
local function compactOrder()
    local w = 1
    for i = 1, orderCount do
        local uid = order[i]
        order[i] = nil
        if uid and threads[uid] then
            order[w] = uid
            w = w + 1
        end
    end
    orderCount = w - 1
    orderHoles = 0
end

-- Tell a thread's parent that its child died, so morbid
local function notifyChildExit(parent, childUid, ok, val)
    if parent and parent ~= childUid and threads[parent] then
        scheduler.signal(parent, scheduler.SIG.CHLD, childUid, ok, val)
    end
end

-- Goodbye thread
local function reap(uid, t)
    local parent = t.parent

    threads[uid] = nil
    threadCount = threadCount - 1
    orderHoles = orderHoles + 1

    if uid ~= activeUid and poolCount < MAX_POOL then
        t.co = nil
        t.wakeAt = nil
        t.waiting = nil
        t.hasResume = nil
        t.resumeVal = nil
        t.inputQueue = nil
        t.inputHead = nil
        t.inputCount = nil
        t.onExit = nil
        t.cancelled = nil
        t.exiting = nil
        t.exitCode = nil
        t.pendingSignal = nil
        t.signalArgs = nil
        t.lastSignal = nil
        t.lastSignalArgs = nil
        t.condemned = nil
        t.handlers = nil
        t.parent = nil
        t.label = nil
        t.spawnedAt = nil
        t.stopped = nil
        t.sleepRemaining = nil
        poolCount = poolCount + 1
        pool[poolCount] = t
    end

    if orderHoles > 16 and orderHoles * 2 > orderCount then
        compactOrder()
    end

    return parent
end

-- This saves a whopping 0.05s crazy right
local function inputPush(t, v)
    local q = t.inputQueue
    if not q then
        q = {}
        t.inputQueue = q
        t.inputHead = 1
        t.inputCount = 0
    end
    q[t.inputHead + t.inputCount] = v
    t.inputCount = t.inputCount + 1
end

local function inputShift(t)
    local q = t.inputQueue
    if not q then return nil end
    local h = t.inputHead
    local n = t.inputCount - 1
    local v = q[h]
    q[h] = nil
    if n == 0 then
        -- reuse stuff? please
        t.inputHead = 1
        t.inputCount = 0
    else
        t.inputHead = h + 1
        t.inputCount = n
    end
    return v
end

local function inputHas(t)
    return t.inputQueue ~= nil and t.inputCount > 0
end


-- Fancy
function scheduler.sleep(seconds)
    checkArg(1, seconds, "number")
    seconds = math_max(0, seconds)
    return coroutine_yield("sleep", seconds)
end

function scheduler.waitForInput()
    return coroutine_yield("readInput")
end

-- Oh look, im yielding a singular tick. Who wouldve thought.
function scheduler.yield()
    return coroutine_yield("sleep", 0)
end

-- I hope so
function scheduler.isSignal(v)
    return type(v) == "string" and SIGSET[v] or false
end

-- Walkie talkie
function scheduler.sendData(uid, value)
    local t = threads[uid]
    if not t then
        return false
    end

    -- I need this bad
    inputPush(t, value)

    if t.waiting then
        t.waiting = false
        t.hasResume = true
        t.resumeVal = inputShift(t)
        t.wakeAt = nil
    end
    return true
end

-- "proper" Signals
-- CHLD: signal(parent, CHLD, childUid, ok, result)
function scheduler.signal(uid, sig, ...)
    local t = threads[uid]
    if not t then return false end

    -- No you cannot handle kill lol
    if sig == scheduler.SIG.KILL then
        return scheduler.kill(uid)
    end
    if sig == scheduler.SIG.TSTP then
        return scheduler.stop(uid)
    end

    -- Thread sees all this
    t.pendingSignal = sig
    t.signalArgs = { ... }

    local h = t.handlers and t.handlers[sig]

    if h then
        -- omg handlers
        h(uid, sig, ...)
    elseif sig == scheduler.SIG.CONT then
        scheduler.cont(uid)
    elseif sig == scheduler.SIG.INT or sig == scheduler.SIG.HUP then
        -- Im so kind, I give it one more resume to deal with cleanup by default
        t.cancelled = true
        t.condemned = true
    end
    -- CHLD does nothing

    -- Hey, wakeup!
    if t.wakeAt ~= nil then
        t.wakeAt = 0
    end
    if t.waiting then
        t.waiting = false
        t.hasResume = false
        t.resumeVal = nil
    end
    return true
end

function scheduler.signalAll(sig)
    local uids = {}
    for uid in pairs(threads) do uids[#uids + 1] = uid end
    for i = 1, #uids do scheduler.signal(uids[i], sig) end
end

-- Left on delivered, tragic
function scheduler.pendingSignal(uid)
    local t = threads[uid or activeUid]
    return t and t.pendingSignal or nil
end

-- Hey, what happened?
function scheduler.lastSignal(uid)
    local t = threads[uid or activeUid]
    if not t then return nil end
    local args = t.lastSignalArgs
    if args then
        return t.lastSignal, unpack(args, 1, args.n or #args)
    end
    return t.lastSignal
end

-- onExit is a bit jank I think
function scheduler.spawn(fn, onExit, label, handlers)
    checkArg(1, fn, "function")
    checkArg(2, onExit, "function", "nil")
    checkArg(3, label, "string", "nil")
    checkArg(4, handlers, "table", "nil")

    nextUid = nextUid + 1
    local uid = nextUid

    -- Reuse a dead record if we have one
    local t
    if poolCount > 0 then
        t = pool[poolCount]
        pool[poolCount] = nil
        poolCount = poolCount - 1
    else
        t = {}
    end

    threads[uid] = t

    t.co = coroutine_create(fn)
    t.wakeAt = nil
    t.waiting = false
    t.hasResume = false
    t.resumeVal = nil
    t.inputQueue = nil
    t.inputHead = nil
    t.inputCount = nil
    t.onExit = onExit
    t.cancelled = false
    t.exiting = false
    t.exitCode = nil
    t.pendingSignal = nil
    t.signalArgs = nil
    t.lastSignal = nil
    t.lastSignalArgs = nil
    t.condemned = false
    -- For the love of god can handlers not be so horrible
    t.handlers = handlers
    t.parent = activeUid
    t.label = label or "?"
    t.spawnedAt = computer_uptime()
    t.stopped = nil
    t.sleepRemaining = nil

    -- order time
    orderCount = orderCount + 1
    order[orderCount] = uid

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
        local entry = {
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
        out[#out + 1] = entry
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
        t.sleepRemaining = math_max(0, t.wakeAt - computer_uptime())
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

-- Makes a coroutine die
function scheduler.kill(uid)
    local t = threads[uid]
    if not t then
        return false
    end

    local onExit = t.onExit
    local parent = reap(uid, t)

    -- Cant exactly do this
    if onExit then
        onExit(false, "killed")
    end

    notifyChildExit(parent, uid, false, "killed")

    return true
end

-- Tells a coroutine to die. This time for real
function scheduler.cancel(uid)
    local t = threads[uid]
    if not t or t.cancelled then
        return false
    end

    t.cancelled = true
    t.condemned = true

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

-- Tells all coroutines to go die
function scheduler.cancelAll()
    for uid in pairs(threads) do
        scheduler.cancel(uid)
    end
end

-- Kills all coroutines
function scheduler.killAll(exceptUid)
    local uids = {}

    for uid in pairs(threads) do
        if uid ~= exceptUid then
            uids[#uids + 1] = uid
        end
    end

    for i = 1, #uids do
        scheduler.kill(uids[i])
    end

    -- I gotta word this better
    if exceptUid and threads[exceptUid] then
        reap(exceptUid, threads[exceptUid])
    end
end

-- Returns the UID of the active thread
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
    if threadCount == 0 then return end

    local thr = threads
    local now = computer_uptime()
    local oc = orderCount

    local i = 1
    while i <= oc do
        local uid = order[i]
        local t = uid and thr[uid]
        if t and not t.waiting and not t.stopped then
            local ready = (t.wakeAt == nil) or (now >= t.wakeAt)
            if ready then
                activeUid = uid

                local ok, a, b, c
                local sig = t.pendingSignal
                if sig ~= nil then
                    -- Signal has priority over input
                    t.pendingSignal = nil
                    t.lastSignal = sig
                    t.lastSignalArgs = t.signalArgs
                    t.signalArgs = nil
                    ok, a, b, c = coroutine_resume(t.co, sig)
                elseif t.hasResume then
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
                    local onExit = t.onExit
                    local exitCode = t.exitCode
                    local parent = reap(uid, t)
                    if onExit then
                        onExit(true, exitCode)
                    end
                    notifyChildExit(parent, uid, true, exitCode)
                elseif not ok then
                    if klog then klog("Scheduler: tick failure: coroutine error! | " .. tostring(a)) end
                    local onExit = t.onExit
                    local parent = reap(uid, t)
                    if onExit then onExit(false, a) end
                    notifyChildExit(parent, uid, false, a)
                elseif coroutine_status(t.co) == "dead" then
                    local onExit = t.onExit
                    local parent = reap(uid, t)
                    if a == "cancelled" then
                        if onExit then onExit(true, "cancelled") end
                        notifyChildExit(parent, uid, true, "cancelled")
                    else
                        if onExit then onExit(true, a, b, c) end
                        notifyChildExit(parent, uid, true, a)
                    end
                else
                    local reason = a

                    if t.condemned then
                        -- Lol its cancelled
                        local onExit = t.onExit
                        local parent = reap(uid, t)
                        if onExit then
                            onExit(true, "cancelled")
                        end
                        notifyChildExit(parent, uid, true, "cancelled")
                    elseif reason == "cancelled" then
                        -- Fix old stuff?
                        local onExit = t.onExit
                        local parent = reap(uid, t)
                        if onExit then
                            onExit(true, "cancelled")
                        end
                        notifyChildExit(parent, uid, true, "cancelled")
                    elseif reason == "sleep" and type(b) == "number" then
                        t.wakeAt = now + b
                        t.waiting = false
                    elseif reason == "readInput" then
                        if inputHas(t) then
                            t.hasResume = true
                            t.resumeVal = inputShift(t)
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
        i = i + 1
    end
end

-- Starts it up
function scheduler.init(event, tickInterval)
    checkArg(1, event, "table")
    checkArg(2, tickInterval, "number", "nil")

    local interval = tickInterval or 0.1
    local handlerId = event.timer(interval, tick, math_huge)

    -- Allowing multiple (in theory)
    handlers[handlerId] = interval

    return handlerId
end

return scheduler