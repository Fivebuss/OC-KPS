-- /sys/kernel/modules/scheduler.lua

-- Lsched v2
-- Ported from MShell and then I did some nonsense to it



--[[

Lsched
Cooperative multitasking. Kinda
Oh look, a bigass comment block. Thanks AI I am not typing all of it this time

scheduler.spawn(fn, onExit, label, handlers): returns cid
    handlers (optional): {
        INT  = function(sig, ...) end,
        CONT = function(sig, ...) end,
        HUP  = function(sig, ...) end,
        CHLD = function(childCid, ok, result, ...) end,
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
    CONT      : scheduler.cont(cid)
    TSTP      : hard stop (Ctrl+Z), not interceptable
    KILL      : hard kill, not interceptable

scheduler.sleep(seconds) -> sig|nil      (now returns a delivered signal, if any)
scheduler.waitForInput() -> value|sig    (a signal can preempt queued input)
scheduler.yield() -> sig|nil             sleep(0). cheap checkpoint, use in loops
scheduler.isSignal(v) -> boolean
scheduler.lastSignal(cid) -> sig, ..
scheduler.sendData(cid, value) -> boolean
scheduler.activeThread() -> cid or nil
scheduler.isBusy() -> boolean
scheduler.threadCount() -> number
scheduler.list() / scheduler.info(cid)
scheduler.signal(cid, sig, ...) -> boolean
scheduler.signalAll(sig)
scheduler.pendingSignal(cid) -> sig|nil
scheduler.init(event, tickInterval) -> handlerId

-- Cancellation --
scheduler.kill(cid): Makes a coroutine die without telling it
scheduler.cancel(cid): Thread dies at its next yield
scheduler.isCancelled(cid): returns boolean
scheduler.killAll(exceptCid)
scheduler.cancelAll()


--]]

local computer = require("computer")
local event = require("event_internals")
local scheduler = {}
local handlers = {}

local unpack = table.unpack or unpack
local pack = table.pack or pack

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
local activeCid = nil
local nextCid = 0

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
        local cid = order[i]
        order[i] = nil
        if cid and threads[cid] then
            order[w] = cid
            w = w + 1
        end
    end
    orderCount = w - 1
    orderHoles = 0
end

-- Tell a thread's parent that its child died, so morbid
local function notifyChildExit(parent, childCid, ok, val)
    if parent and parent ~= childCid and threads[parent] then
        scheduler.signal(parent, scheduler.SIG.CHLD, childCid, ok, val)
    end
end

-- Goodbye thread
local function reap(cid, t)
    local parent = t.parent

    threads[cid] = nil
    threadCount = threadCount - 1
    orderHoles = orderHoles + 1

    if cid ~= activeCid and poolCount < MAX_POOL then
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

        t.eventFilter = nil
        t.eventDeadline = nil
        t.resumeArgs = nil
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

-- Event fix
function scheduler.waitForEvent(timeout, filter)
    checkArg(1, timeout, "number", "nil")
    checkArg(2, filter, "function", "nil")

    return coroutine_yield("event", timeout, filter)
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
function scheduler.sendData(cid, value)
    local t = threads[cid]
    if not t then
        return false
    end

    -- I need this bad
    inputPush(t, value)

    if t.waiting and not t.eventFilter then
        t.waiting = false
        t.hasResume = true
        t.resumeVal = inputShift(t)
        t.wakeAt = nil
    end
    return true
end

-- "proper" Signals
-- CHLD: signal(parent, CHLD, childCid, ok, result)
function scheduler.signal(cid, sig, ...)
    local t = threads[cid]
    if not t then return false end

    -- No you cannot handle kill lol
    if sig == scheduler.SIG.KILL then
        return scheduler.kill(cid)
    end
    if sig == scheduler.SIG.TSTP then
        return scheduler.stop(cid)
    end

    -- Thread sees all this
    t.pendingSignal = sig
    t.signalArgs = { ... }

    local h = t.handlers and t.handlers[sig]

    if h then
        -- omg handlers
        h(cid, sig, ...)
    elseif sig == scheduler.SIG.CONT then
        scheduler.cont(cid)
    elseif sig == scheduler.SIG.INT or sig == scheduler.SIG.HUP then
        -- Im so kind, I give it one more resume to deal with cleanup by default
        t.cancelled = true
        t.condemned = true
    end
    -- CHLD does nothing

    -- Hey, wakeup! and prioritize event signals
    if t.waiting then
        t.waiting = false

        if t.eventFilter then
            t.eventFilter = nil
            t.eventDeadline = nil
            t.resumeArgs = nil
        end

        t.hasResume = false
        t.resumeVal = nil
    end
    return true
end

function scheduler.signalAll(sig)
    local uids = {}
    for cid in pairs(threads) do uids[#uids + 1] = cid end
    for i = 1, #uids do scheduler.signal(uids[i], sig) end
end

-- Left on delivered, tragic
function scheduler.pendingSignal(cid)
    local t = threads[cid or activeCid]
    return t and t.pendingSignal or nil
end

-- Hey, what happened?
function scheduler.lastSignal(cid)
    local t = threads[cid or activeCid]
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

    nextCid = nextCid + 1
    local cid = nextCid

    -- Reuse a dead record if we have one
    local t
    if poolCount > 0 then
        t = pool[poolCount]
        pool[poolCount] = nil
        poolCount = poolCount - 1
    else
        t = {}
    end

    threads[cid] = t

    t.co = coroutine_create(fn)
    t.wakeAt = nil
    t.waiting = false
    t.hasResume = false
    t.resumeVal = nil
    -- Fix events
    t.eventFilter = nil
    t.eventDeadline = nil
    t.resumeArgs = nil
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
    t.parent = activeCid
    t.label = label or "?"
    t.spawnedAt = computer_uptime()
    t.stopped = nil
    t.sleepRemaining = nil

    -- order time
    orderCount = orderCount + 1
    order[orderCount] = cid

    threadCount = threadCount + 1

    return cid
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
    for cid, t in pairs(threads) do
        local entry = {
            cid = cid,
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
function scheduler.info(cid)
    local t = threads[cid]
    if not t then return nil end
    local now = computer_uptime()
    return {
        cid = cid,
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
function scheduler.stop(cid)
    local t = threads[cid]
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
function scheduler.cont(cid)
    local t = threads[cid]
    if not t or not t.stopped then return false end

    t.stopped = false
    t.pendingSignal = scheduler.SIG.CONT

    if t.sleepRemaining ~= nil then
        t.wakeAt = computer_uptime() + t.sleepRemaining
        t.sleepRemaining = nil
    end
    return true
end

function scheduler.isStopped(cid)
    local t = threads[cid or activeCid]
    return t ~= nil and t.stopped or false
end

-- Makes a coroutine die
function scheduler.kill(cid)
    local t = threads[cid]
    if not t then
        return false
    end

    local onExit = t.onExit
    local parent = reap(cid, t)

    -- Cant exactly do this
    if onExit then
        onExit(false, "killed")
    end

    notifyChildExit(parent, cid, false, "killed")

    return true
end

-- Tells a coroutine to die. This time for real
function scheduler.cancel(cid)
    local t = threads[cid]
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

        t.eventFilter = nil
        t.eventDeadline = nil
        t.resumeArgs = nil

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

    local cid = activeCid
    local t = threads[cid]

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

        t.eventFilter = nil
        t.eventDeadline = nil
        t.resumeArgs = nil

        t.hasResume = true
        t.resumeVal = nil
    end

    return true
end

-- Check cancellation flag for any cid
function scheduler.isCancelled(cid)
    local t = threads[cid or activeCid]
    return t ~= nil and t.cancelled or false
end

-- Tells all coroutines to go die
function scheduler.cancelAll()
    for cid in pairs(threads) do
        scheduler.cancel(cid)
    end
end

-- Kills all coroutines
function scheduler.killAll(exceptCid)
    local uids = {}

    for cid in pairs(threads) do
        if cid ~= exceptCid then
            uids[#uids + 1] = cid
        end
    end

    for i = 1, #uids do
        scheduler.kill(uids[i])
    end

    -- I gotta word this better
    if exceptCid and threads[exceptCid] then
        reap(exceptCid, threads[exceptCid])
    end
end

-- Returns the CID of the active thread
function scheduler.activeThread()
    return activeCid or nil
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

-- This bigass function handles event pulling
local function wakeEventWaiters(...)
    local args = pack(...)

    for _, t in pairs(threads) do
        if t.waiting and t.eventFilter then
            local ok, matched = pcall(
                t.eventFilter,
                unpack(args, 1, args.n)
            )

            if ok and matched then
                t.waiting = false
                t.eventFilter = nil
                t.eventDeadline = nil

                t.hasResume = true
                t.resumeVal = nil
                t.resumeArgs = args

                t.wakeAt = nil
            end
        end
    end
end

-- Tick
local function tick(...)
    if threadCount == 0 then return end

    local thr = threads
    local now = computer_uptime()
    local oc = orderCount

    -- Oh boy
    if select("#", ...) > 0 then -- never used select before
        wakeEventWaiters(...)
    end

    for _, t in pairs(thr) do
        if
            t.waiting
            and t.eventFilter
            and t.eventDeadline
            and now >= t.eventDeadline
        then
            t.waiting = false
            t.eventFilter = nil
            t.eventDeadline = nil

            t.hasResume = true
            t.resumeVal = nil
            t.resumeArgs = nil
        end
    end


    local i = 1
    while i <= oc do
        local cid = order[i]
        local t = cid and thr[cid]
        if t and not t.waiting and not t.stopped then
            local ready = (t.wakeAt == nil) or (now >= t.wakeAt)
            if ready then
                activeCid = cid

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
                    local args = t.resumeArgs
                    local v = t.resumeVal

                    t.hasResume = false
                    t.resumeVal = nil
                    t.resumeArgs = nil

                    if args then
                        ok, a, b, c = coroutine_resume(
                            t.co,
                            unpack(args, 1, args.n)
                        )
                    else
                        ok, a, b, c = coroutine_resume(t.co, v)
                    end
                elseif t.wakeAt ~= nil then
                    ok, a, b, c = coroutine_resume(t.co)
                else
                    ok, a, b, c = coroutine_resume(t.co, ...)
                end

                activeCid = nil

                -- thread might have been killed by itself or another thread
                -- mid-resume
                if thr[cid] ~= t then
                    -- gone already, nothing more to do
                elseif t.exiting then
                    local onExit = t.onExit
                    local exitCode = t.exitCode
                    local parent = reap(cid, t)
                    if onExit then
                        onExit(true, exitCode)
                    end
                    notifyChildExit(parent, cid, true, exitCode)
                elseif not ok then
                    if klog then klog("Scheduler: tick failure: coroutine error! | " .. tostring(a)) end
                    local onExit = t.onExit
                    local parent = reap(cid, t)
                    if onExit then onExit(false, a) end
                    notifyChildExit(parent, cid, false, a)
                elseif coroutine_status(t.co) == "dead" then
                    local onExit = t.onExit
                    local parent = reap(cid, t)
                    if a == "cancelled" then
                        if onExit then onExit(true, "cancelled") end
                        notifyChildExit(parent, cid, true, "cancelled")
                    else
                        if onExit then onExit(true, a, b, c) end
                        notifyChildExit(parent, cid, true, a)
                    end
                else
                    local reason = a

                    if t.condemned then
                        -- Lol its cancelled
                        local onExit = t.onExit
                        local parent = reap(cid, t)
                        if onExit then
                            onExit(true, "cancelled")
                        end
                        notifyChildExit(parent, cid, true, "cancelled")
                    elseif reason == "cancelled" then
                        -- Fix old stuff?
                        local onExit = t.onExit
                        local parent = reap(cid, t)
                        if onExit then
                            onExit(true, "cancelled")
                        end
                        notifyChildExit(parent, cid, true, "cancelled")
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
                    elseif reason == "event" then
                        t.eventFilter = c
                        t.eventDeadline =
                            b and (now + math_max(0, b)) or math_huge

                        t.wakeAt = nil
                        t.waiting = true
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
    local handlerId = event.register(nil, function(...)
        tick(...)
    end, interval, math_huge)

    -- Allowing multiple (in theory)
    handlers[handlerId] = interval

    return handlerId
end

return scheduler