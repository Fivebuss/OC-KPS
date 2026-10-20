-- /bin/login.lua
-- Multi-user time! yay
-- We can just ripoff initconsole lol

local process = polaris.process
local io = require("io")
local users = require("users")
local filesystem = require("filesystem")
local gpu = polaris.console._spawnGpu

local console = polaris.console.openTTY({
    gpu   = polaris.console._spawnGpu,
    owner = process.self() and process.self().pid,
})

local isDebug = false

-- mmmm braille trick
console:setCursorShape("underline")
console.disabled.Z = true

if not isDebug then
    console:clear()
end

local function launchKShell(user, uid)
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

        return fn()
    end, {
        cmd = "/bin/ksh.lua",
        label = "ksh",
        ppid = 1,
        pgid = process.GID.FG,
        uid = uid,

        onExit = function(success, exitCode)
            if not success then
                status(exitCode)
            end
        end,
    })

    return shellPid
end

local function loginLoop()
    console:clear()
    console:write(polaris.version.os .. " Login\ntty bound to GPU " .. tostring(gpu) .. "\n")

    local stdin = process.input()

    while true do
        console:write("login: ")
        console:flush()

        local line = stdin:readLine()
        line = line:gsub("[\r\n]", "")

        if line == "" then
            console:clear()
        elseif line == "?proc" then
            local info = process.self()
            local keys = {}

            for key in pairs(info) do
                keys[#keys + 1] = key
            end

            table.sort(keys)

            for _, key in ipairs(keys) do
                console:write(tostring(key), ": ", tostring(info[key]), "\n")
            end
        elseif not users.exists(line) then
            console:write("User '" .. line .. "' does not exist\n")
        else
            --console:write("Found user " .. line .. "!\n")
            local uid = users.lookup(line)
            --console:write("Found user id " .. uid)

            launchKShell(line, uid)
            console:clear()
            console:write("Loading /bin/ksh.lua as UID " .. uid)
            console:flush()
            console:close()
            return
        end
    end
end


local loginShell
loginShell = process.spawn(loginLoop, {
    cmd = "/bin/login.lua",
    label = ("login_shell_" .. tostring(gpu)):sub(1, 15),
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
process.create(loginShell, console.reader, console, console)

-- Register this thread as the "owner" of the console
if console.attach then
    console:attach(loginShell)
end
