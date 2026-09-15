-- /bin/ksh.lua
-- Okay im abt 1% the way to porting MShell

local process = polaris.process
local filesystem = require("filesystem")

-- hope
local path = "/bin:/sbin"

-- every spawned process gets this
local function createProcessIO()
    local pio = {}

    function pio.write(...)
        return process.write(...)
    end

    function pio.writeln(...)
        process.write(...)
        return process.write("\n")
    end

    function pio.read(...)
        return process.input():read(...)
    end

    function pio.readline(...)
        return process.input():readLine(...)
    end

    function pio.writeError(...)
        return process.writeError(...)
    end

    function pio.writelnError(...)
        process.writeError(...)
        return process.writeError("\n")
    end

    function pio.flush()
        return process.output():flush()
    end

    -- The fds
    pio.stdin = process.input()
    pio.stdout = process.output()
    pio.stderr = process.error()

    return pio
end

-- : seperated in theory
local function splitPath(p)
    local parts = {}
    for entry in p:gmatch("[^:]+") do
        table.insert(parts, entry)
    end
    return parts
end

local pathDirs = splitPath(path)

local function resolveCommand(name)
    if name == "ksh" then return nil end
    for _, dir in ipairs(pathDirs) do
        local candidate = filesystem.concat(dir, name .. ".lua")
        if filesystem.exists(candidate) and not filesystem.isDirectory(candidate) then
            return candidate
        end
    end
    return nil
end

-- I wonder what this does
local function writeRed(stream, ...)
    stream:write("\27[31m")
    stream:write(...)
    return stream:write("\27[0m")
end

local tty = polaris.tty.new(polaris.gpu)
tty:setCursorShape("underline")

tty.disabled.C = true
tty.disabled.D = true
tty.disabled.Z = true

polaris.config["tty.profile"] = 7

local shellPid

-- Out
local function createOutStream()
    return {
        write = function(self, ...)
            return tty:write(...)
        end,
        close = function(self) end,
    }
end

-- Out but red
local function createErrStream()
    return {
        write = function(self, ...)
            return writeRed(tty, ...)
        end,
        close = function(self) end,
    }
end

-- I dont use this right now
local function createInStream()
    return {
        read = function(self, n)
            return nil -- nothing to give yet, EOF style
        end,
        close = function(self) end,
    }
end

-- Builtin stuff
local builtins = {}

function builtins.clear()
    tty:clear()
end

function builtins.exit()
    process.exit(0)
end

-- This global is also available, will house some console info or something
local console = {

}

-- Processes
local function runCommand(pathToFile, name)
    local pid
    local waiterPid = process.self()

    pid = process.spawn(function()
        local env = polaris.env.current()
        env.console = console
        env.io = createProcessIO()

        local ok, err = xpcall(function()
            local fn, loadErr = env.load(assert(select(2, pcall(function()
                local f = assert(filesystem.open(pathToFile, "r"))
                local buf = {}
                while true do
                    local chunk = f:read(math.maxinteger or math.huge)
                    if not chunk then break end
                    buf[#buf + 1] = chunk
                end
                f:close()
                return table.concat(buf)
            end))), "=" .. pathToFile, "bt")

            if not fn then
                error(fn == nil and loadErr or fn, 0)
            end

            return fn()
        end, debug.traceback)

        if not ok then
            process.error():write("\27[31m", tostring(err), "\n\27[0m")
        end
    end, {
        label = name,
        pgid = process.GROUP.USERFG,
        ppid = shellPid,
        onExit = function(success, reason)
            process.send(waiterPid, true)
        end,
    })

    process.create(pid, createInStream(), createOutStream(), createErrStream())

    if tty.attach then
        tty:attach(pid)
    end

    process.waitForInput()

    return pid
end

local function shellLoop()
    tty:clear()
    tty:write("ksh loaded\n")

    local stdin = process.input()

    while true do
        tty:write("> ")
        tty:flush()

        local line = stdin:readLine()

        if not line then
            tty:write("\n")
            return
        end

        line = line:gsub("[\r\n]", "")
        local name = line:match("^%s*(%S+)%s*$")

        if name then
            local builtin = builtins[name]

            if builtin then
                local ok, err = xpcall(builtin, debug.traceback)
                if not ok then
                    writeRed(tty, tostring(err), "\n")
                end
            else
                local resolved = resolveCommand(name)

                if resolved then
                    local ok, err = xpcall(function()
                        return runCommand(resolved, name)
                    end, debug.traceback)

                    if not ok then
                        writeRed(tty, tostring(err), "\n")
                    end
                else
                    writeRed(tty, "ksh: command not found: " .. name, "\n")
                end
            end
        end
    end
end

shellPid = process.spawn(shellLoop, {
    label = "ksh",
    pgid = process.GROUP.USER,
    onExit = function(success, reason)
        computer.beep(2000)
        computer.beep(2000)

        if tty.attach then
            tty:setCursor(false)
            tty:clear()
            tty:detach(shellPid)
            tty:close()
        end
        process.destroy(shellPid)
    end,
})

process.create(shellPid, tty.reader, tty, tty)

if tty.attach then
    tty:attach(shellPid)
end
