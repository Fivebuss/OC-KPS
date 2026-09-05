-- /boot/util/initconsole.lua
-- Basic shell for testing and if it cant reach further down boot

local scheduler = polaris.scheduler
local io = require("sys.kernel.modules.io")

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
}

if not isDebug then
    console:clear()
end

local function initShell()
    console:write("Init console loaded\n")
    while true do

        coroutine.yield()
        console:write("> ")

        local line = io.input(scheduler):readLine():gsub("\n$", "")
        if not line then
            return
        end

        local command = commands[line]

        if command then
            command(cenv)
        else
            io.write(scheduler, "unknown command: ", line, "\n")
        end
    end
end

local shellUid
shellUid = scheduler.spawn(initShell, function(success, reason)
    io.cleanupThread(shellUid)
    if not success and reason ~= "killed" then
        error(reason)
    end
end, "init_console")

io.initThread(shellUid, console.reader, console, console)
