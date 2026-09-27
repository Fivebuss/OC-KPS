-- /boot/util/initconsole.lua
-- Basic shell for testing and if it cant reach further down boot

-- I hope this works
local process = polaris.process
local io = require("io")

polaris.config["tty.profile"] = 7
_G.console = polaris.tty.new(polaris.gpu)
local isDebug = false

-- mmmm braille trick
console:setCursorShape("underline")

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
    process = process,
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

    local stdin = process.input()

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

local shellPid
shellPid = process.spawn(initShell, {
    label = "init_console",
    onExit = function(success, reason)
        computer.beep(2000)
        computer.beep(2000)
        computer.beep(2000)
        process.destroy(shellPid)
    end,
})

-- stdin isnt used really
process.create(shellPid, console.reader, console, console)

-- Register this thread as the "owner" of the console
if console.attach then
    console:attach(shellPid)
end