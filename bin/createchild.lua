-- /bin/createchild.lua

-- Onexit testing
local event = require("event")
local process = require("process")
local args = { ... }

if #args < 2 or type(args[1]) ~= "string" then
    io.stderr:writeln("createchild: Invalid arguements")
    os.exit(1)
end

local child = function()
    local code, err = load(args[1], "createchild")

    if not code then
        io.stderr:writeln("createchild: " .. tostring(err))
        os.exit(1)
    end

    local pid
    pid = process.spawn(code, {
        label = args[2],
        gid = process.GROUP.USER,
        onOrphaned = function()
            computer.beep(2000)
        end,
        onExit = function(success, reason)
            process.destroy(pid)
        end,
        handlers = {
            INT = function(uid, sig)
            end,

            HUP = function(uid, sig)
            end,
        },
    })

    return pid
end

local cpid = child()

io.writeln("Created process " .. tostring(cpid))
--process.waitForInput()
