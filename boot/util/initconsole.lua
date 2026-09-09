-- /boot/util/initconsole.lua
-- Basic shell for testing and if it cant reach further down boot

local scheduler = polaris.scheduler
local io = require("sys.kernel.modules.io")

polaris.config["tty.profile"] = 7
_G.console = polaris.tty.new(gpu)
local isDebug = false

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
    console:write("Init console loaded\n")
    polaris.log("Init console loaded")
    while true do
        console:write("> ")
        console:flush()

        -- Get stdin for the current thread and read
        local stdin = io.input(scheduler)
        local line = stdin:readLine()

        if not line then
            console:write("\n")
            return
        end

        -- Get rid of line end
        line = line:gsub("[\r\n]", "")

        local command = commands[line]

        if command then
            command(cenv)
        else
            io.write(scheduler, "unknown command: ", line, "\n")
        end
        console:flush()
    end
end

local shellUid
shellUid = scheduler.spawn(initShell, function(success, reason)
    assert(success, reason)
    io.cleanupThread(shellUid)
end, "init_console")

-- stdin isnt used really
io.initThread(shellUid, console.reader, console, console)

-- Register this thread as the "owner" of the console
if console.attach then
    console:attach(shellUid)
end