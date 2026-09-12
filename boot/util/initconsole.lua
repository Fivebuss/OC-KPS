-- /boot/util/initconsole.lua
-- Basic shell for testing and if it cant reach further down boot

local scheduler = polaris.scheduler
local io = require("sys.kernel.modules.io")

polaris.config["tty.profile"] = 7
_G.console = polaris.tty.new(gpu)
local isDebug = false

-- mmmm braille trick
--console:setCursorShape("braille")

-- Dont need them
console.disabled.C = true
console.disabled.D = true
console.disabled.Z = true

local ok, commands = pcall(require, "/boot/util/confunctions")
if not ok then
    error("initconsole: failed to load confunctions.lua: " .. tostring(commands))
end

local cenv = {
    io = io,
    scheduler = scheduler,
    console = console,
    debug = polaris.config["debug"],
    config = polaris.config,
}

if not isDebug then
    console:clear()
end

local function initShell()
    console:clear()
    console:write("Init console loaded\n")

    local stdin = io.input(scheduler)

    while true do
        console:write("> ")
        console:flush()

        local line = stdin:readLine()

        if not line then
            console:write("\n")
            return
        end

        line = line:gsub("[\r\n]", "")

        local command = commands[line]

        if command then
            command(cenv)
        else
            console:write("unknown command: ", line, "\n")
        end
    end
end

local shellUid
shellUid = scheduler.spawn(initShell, function(success, reason)
    assert(success, reason)
    console:write("Console exit\n")
    computer.beep(2000)
    computer.beep(2000)
    computer.beep(2000)
    io.cleanupThread(shellUid)
end, "init_console")

-- stdin isnt used really
io.initThread(shellUid, console.reader, console, console)

-- Register this thread as the "owner" of the console
if console.attach then
    console:attach(shellUid)
end