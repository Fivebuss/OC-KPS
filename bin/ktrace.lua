-- /bin/ktrace.lua
-- Gives some useful info about a process

local process = polaris.process
local scheduler = polaris.scheduler

local showInfo = false
local showTrace = false
local pid

for _, arg in ipairs(args) do
    if arg == "-i" then
        showInfo = true
    elseif arg == "-t" then
        showTrace = true
    elseif not pid then
        pid = arg
    else
        io.writelnError("ktrace: Unexpected argument " .. tostring(arg))
        os.exit(1)
    end
end

-- default is -t
if not showInfo and not showTrace then
    showTrace = true
end

if not pid then
    io.writelnError("ktrace: Usage: ktrace [-i] [-t] PID")
    os.exit(1)
end

pid = tonumber(pid)

if not pid or pid % 1 ~= 0 or not process.exists(pid) then
    io.writelnError("ktrace: Invalid PID " .. tostring(pid))
    os.exit(1)
end

local function getInfo(pid)
    local p = process.get(pid)
    if not p then return "Process not found" end

    local lines = {
        "Process table:",
        "PID: " .. tostring(p.pid),
        "PPID: " .. tostring(p.ppid),
        "UID: " .. tostring(p.uid),
        "GID: " .. tostring(p.gid),
        "Command: " .. tostring(p.cmd),
        "Label: " .. tostring(p.label),

        "",
        "Scheduler table:",
        "Status: " .. tostring(p.status),
        "Waiting: " .. tostring(p.waiting),
        "Sleeping: " .. tostring(p.sleeping),
        "Cancelled: " .. tostring(p.cancelled),
        "Stopped: " .. tostring(p.stopped),
        "Age: " .. tostring(p.age),
        "Spawned at: " .. tostring(p.spawnedAt),

        "",
        "Relations:",
        "Parent: " .. tostring(process.parent(pid)),
        "Children: " .. table.concat(process.children(pid), ", "),

        "",
        "Groups:",
        "UID: " .. tostring(p.uid),
        "GID: " .. tostring(p.gid),
        "Members: " .. table.concat(
            process.groupMembers(p.uid, p.gid), ", "
        ),

        "",
        "Pending signal: " .. tostring(process.pendingSignal(pid)),

        "",
        "Other:",
        "Protected: " .. tostring(p.protected),
        "CTTY: " .. tostring(p.ctty),
        "Exists: " .. tostring(process.exists(pid)),
    }

    return table.concat(lines, "\n")
end

io.writeln("Debugging information for PID " .. tostring(pid))

if showInfo then
    io.writeln(getInfo(pid))
end

if showTrace then
    io.writeln(scheduler.traceback(pid) or "No traceback available")
end