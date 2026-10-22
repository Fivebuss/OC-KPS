-- /bin/rc.lua
-- I finally got around to doing it

-- rc                           list services
-- rc <name> [status]           state and log
-- rc <name> start|stop|restart
-- rc <name> <func> [args...]   call a arbitrary function

local services = polaris.services

local BUILTIN = { start = true, stop = true, restart = true, status = true }
local DONE = { start = "started", stop = "stopping", restart = "restarting" }

local function secs(t)
    return string.format("%.2fs", t or 0)
end

local function list()
    local rows = { { "SERVICE", "STATE", "PRI", "ONEXIT", "LABEL" } }
    for _, name in ipairs(services.list()) do
        local s = services.status(name)
        rows[#rows + 1] = { s.name, s.state, tostring(s.priority), s.onExit, s.label }
    end

    local widths = {}
    for _, row in ipairs(rows) do
        for i, cell in ipairs(row) do widths[i] = math.max(widths[i] or 0, #cell) end
    end
    for _, row in ipairs(rows) do
        for i = 1, #row - 1 do row[i] = row[i] .. string.rep(" ", widths[i] - #row[i]) end
        io.writeln(table.concat(row, "  "))
    end
end

local function status(name)
    local s, err = services.status(name)
    if not s then
        io.writelnError("rc: " .. err)
        return
    end

    local log = services.log(name)
    if s.starts == 0 then
        io.writeln(name .. ": never started")
    else
        io.writeln(s.label == s.name and s.name or string.format("%s (%s)", s.name, s.label))
        io.writeln("  exec     " .. s.exec)
        io.writeln(string.format("  priority %d, onExit %s, autostart %s", s.priority, s.onExit, tostring(s.autostart)))
        io.writeln("  state    " .. s.state)

        if s.proc then
            io.writeln(string.format("  process  pid %d, ppid %s, gid %s, up %s",
                s.proc.pid, tostring(s.proc.ppid), tostring(s.proc.gid), secs(s.proc.age)))
        end
        io.writeln(string.format("  spawned  %s (%d start%s)", secs(s.startedAt), s.starts, s.starts == 1 and "" or "s"))
        if s.last then
            io.writeln(string.format("  stopped  %s, %s%s", secs(s.stoppedAt), s.last.text,
                s.last.requested and " (requested)" or ""))
        end
        if #s.exports > 0 then
            io.writeln("  exports  " .. table.concat(s.exports, ", "))
        end
    end

    if #log > 0 then
        io.writeln("log:")
        for _, line in ipairs(log) do io.writeln(line) end
    end
end

local name, action = args[1], args[2]

if name == nil or (name == "status" and action == nil) then
    return list()
end
-- rc status <name> works maybe? Yes
if BUILTIN[name] and action and not BUILTIN[action] then
    name, action = action, name
end
action = action or "status"

if action == "status" then
    return status(name)
elseif action == "start" or action == "stop" or action == "restart" then
    local ok, err = polaris.call("service", action, name)
    if ok then
        io.writeln(name .. ": " .. DONE[action])
    else
        io.writelnError("rc: " .. tostring(err))
    end
else
    -- Run a function with args
    local callArgs = {}
    for i = 3, #args do callArgs[#callArgs + 1] = args[i] end

    local ok, err = services.call(name, action, table.unpack(callArgs))
    if not ok then
        io.writelnError("rc: " .. tostring(err))
    elseif err ~= nil then

        io.writeln(tostring(ok))
        if err ~= nil then io.writeln(tostring(err)) end
    end
end