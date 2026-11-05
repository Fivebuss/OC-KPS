-- /bin/login.lua
-- Multi-user time! yay
-- We can just ripoff inittty lol

local process = polaris.process
local io = require("io")
local users = require("users")
local filesystem = require("filesystem")
local gpu = ...

local tty = polaris.console.openTTY({
    gpu   = gpu,
    owner = process.self() and process.self().pid,
})

local isDebug = false

-- mmmm braille trick
tty:setCursorShape("invert")
tty.disabled.Z = true
tty.disabled.C = true
tty.disabled.D = true

if not isDebug then
    tty:clear()
end

local function launchKShell(user, uid)
    local waiterPid = process.self().pid
    local shellPid
    polaris.analytics.addEvent("kshlaunch-" .. uid)

    shellPid = process.spawn(function()
        local env = polaris.env.current()

        env.home = "/home/" .. user
        env.setenv("USER", user)
        env.setenv("HOME", env.home)
        env.gpu = gpu

        local src, reason = filesystem.open("/bin/ksh.lua", "r")
        if not src then
            error(reason or "cannot open /bin/ksh.lua", 0)
        end

        local chunks = {}
        while true do
            local chunk = src:read(math.huge)
            if not chunk then break end
            chunks[#chunks + 1] = chunk
        end
        src:close()

        local fn, loadErr = env.load(
            table.concat(chunks),
            "=/bin/ksh.lua",
            "bt"
        )

        if not fn then
            error(loadErr, 0)
        end

        fn()

        process.waitForInput()
    end, {
        cmd = "/bin/login.lua",
        label = "logind-watchdog-" .. waiterPid,
        ppid = waiterPid,
        gid = process.GID.USER,
        uid = uid,

        onExit = function(success, exitCode)
            if not success then
                polaris.log(exitCode)
                polaris.panic()
            end

            process.send(waiterPid, true)
        end,
    })

    -- I forgot to just wait until ksh dies lmao
    process.waitForInput()

    return shellPid
end

local function loginLoop()
    tty:clear()
    tty:write("KPS v" .. polaris.version.os .. " Login\ntty bound to GPU " .. tostring(gpu) .. "\n")

    local stdin = process.input()

    while true do
        tty:write("login: ")
        tty:flush()

        local line = stdin:readLine()
        line = line:gsub("[\r\n]", "")

        if line == "" then
            tty:clear()
        elseif line == "?proc" then
            local info = process.self()
            local keys = {}

            for key in pairs(info) do
                keys[#keys + 1] = key
            end

            table.sort(keys)

            for _, key in ipairs(keys) do
                tty:write(tostring(key), ": ", tostring(info[key]), "\n")
            end
        elseif not users.exists(line) then
            tty:write("User '" .. line .. "' does not exist\n")
        else
            --tty:write("Found user " .. line .. "!\n")
            local uid = users.lookup(line)
            --tty:write("Found user id " .. uid)

            tty:clear()
            tty:write("Loading /bin/ksh.lua as UID " .. uid)
            tty:flush()
            tty:close()

            launchKShell(line, uid)

            -- I will just assume tty wont change lol
            tty = polaris.console.openTTY({
                gpu   = gpu,
                owner = process.self().pid,
            })

            tty:setCursorShape("invert")
            tty.disabled.Z = true
            tty.disabled.C = true
            tty.disabled.D = true

            process.create(process.self().pid, tty.reader, tty, tty)

            -- Own it
            if tty.attach then
                tty:attach(process.self().pid)
            end

            stdin = process.input()

            -- And the login loop lives again
            tty:clear()
            tty:write("KPS v" .. polaris.version.os .. " Login\ntty bound to GPU " .. tostring(gpu) .. "\n")
        end
    end
end


local loginShell
loginShell = process.spawn(loginLoop, {
    cmd = "/bin/login.lua",
    label = ("logind-" .. tostring(gpu)):sub(1, 10),
    gid = process.GID.USER,
    onExit = function(success, reason)
        if not success then
            local trace = debug.traceback(reason)
            for line in trace:gmatch("[^\r\n]+") do
                polaris.log(line)
            end
        end
        process.destroy(loginShell)
    end,
})

-- stdin isnt used really
process.create(loginShell, tty.reader, tty, tty)

-- Register this thread as the "owner" of the tty
if tty.attach then
    tty:attach(loginShell)
end
