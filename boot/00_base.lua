-- Extending functionality for stuff
-- And modifying global stuff
local process = polaris.process
polaris.analytics.addEvent("stage2")
polaris.env = require("env")

-- Replace os.sleep
function os.sleep(n)
    checkArg(1, n, "number")
    if process.self() then
        process.sleep(n)
    else
        error("os.sleep called outside a process")
    end

    return true
end

-- os.exit
function os.exit(code)
    if code == nil or code < 0 or code > 255 then
        code = 0
    end
    process.exit(code)
    return false
end

-- Does two things, destroys old managed _ENVs and it determines which one to copy
do
    local rawSpawn = process.spawn

    function process.spawn(fn, opts)
        checkArg(1, fn, "function")
        checkArg(2, opts, "table", "nil")
        opts = opts or {}

        local userOnExit = opts.onExit
        local wrapped = {}
        for k, v in pairs(opts) do wrapped[k] = v end

        -- Spawned in kernel so gets a modified _G
        local parentEnv = polaris.env.current() or polaris.env.new()

        local pid
        wrapped.onExit = function(success, reason, ...)
            if pid then
                polaris.env.destroy(pid)
            end
            if userOnExit then
                userOnExit(success, reason, ...)
            end
        end

        pid = rawSpawn(fn, wrapped)
        polaris.env.forProcess(pid, parentEnv)
        return pid
    end
end

-- Lol reads the entire files contents
local function readFile(path)
    local filesystem = require("filesystem")
    local file, reason = filesystem.open(path, "r")
    if not file then
        return nil, reason or ("cannot open " .. tostring(path))
    end

    local buffer = {}
    while true do
        local chunk = file:read(math.maxinteger or math.huge)
        if not chunk then break end
        buffer[#buffer + 1] = chunk
    end
    file:close()

    return table.concat(buffer)
end

-- Now uses a _ENV
function loadfile(path)
    local buffer, reason = readFile(path)
    if not buffer then
        return nil, reason
    end

    local target = polaris.env.current()
    local fn, err = target.load(buffer, "=" .. path, "bt")
    if not fn then
        return nil, err
    end

    return fn
end

function dofile(path, ...)
    local fn, err = loadfile(path)
    if not fn then
        error(err, 0)
    end
    return fn(...)
end

-- Just an alias really to process.spawn
function os.execute(path, opts)
    checkArg(1, path, "string")
    checkArg(2, opts, "table", "nil")

    local buffer, reason = readFile(path)
    if not buffer then
        return nil, reason
    end

    return process.spawn(function()
        local env = polaris.env.current()
        local fn, err = env.load(buffer, "=" .. path, "bt")
        if not fn then
            error(err, 0)
        end
        return fn()
    end, opts)
end

-- mmmmmm syscalls

local function unmountAll()
    local filesystem = require("filesystem")
    local mounts = {}

    for fs, path in filesystem.mounts() do
        if path ~= "/" and path ~= "/dev" and path ~= "/proc" and path ~= "/tmp" then
            mounts[#mounts + 1] = path
        end
    end

    -- Yes. We count bind mounts.
    table.sort(mounts, function(a, b)
        local da = select(2, a:gsub("/", ""))
        local db = select(2, b:gsub("/", ""))

        if da == db then
            return #a > #b
        end

        return da > db
    end)

    local results = {}

    for _, path in ipairs(mounts) do
        local ok, result, reason = pcall(filesystem.umount, path)

        results[path] = {
            success = ok and result ~= false,
            reason = not ok and result or reason,
        }
    end

    return results
end

-- c
polaris.sysrq.register(99, function()
    -- computer.beep(1000)
    -- polaris.panic()
    computer.beep(2000)
    computer.beep(2000)
    polaris.panic()
end)
-- o
polaris.sysrq.register(111, function()
    computer.shutdown()
end)
-- u
polaris.sysrq.register(117, function()
    polaris.log("Sysrq: Unmounting user mounts")
    local ok, result = unmountAll()
    if result ~= false then
        polaris.log("Failed ummountall(): " .. reason)
    end
end)
