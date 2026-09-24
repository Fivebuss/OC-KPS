-- Yes yes super basic
-- Ripped metatable shenanigans from syslog
-- I have a 'super cool' ring buffer library but wont use it since this guy is special
local scheduler = polaris.scheduler

local maxLines = (polaris.config and polaris.config["kernel_log_buffer_length"]) or 128

local lines = {}
local head = 1
local count = 0

local log = {}

local metatable = {
    __index = log,
    __call = function(self, data) self:write(data) end,
    __tostring = function(self) return self:tostring() end,
}

local function push(line)
    lines[head] = line
    head = (head % maxLines) + 1
    count = math.min(count + 1, maxLines)
end

function log:tostring()
    if count == 0 then return "" end
    local out = {}
    local start = count < maxLines and 1 or head
    for i = 0, count - 1 do
        local idx = ((start - 1 + i) % maxLines) + 1
        out[#out + 1] = lines[idx]
    end
    return table.concat(out)
end

function log:write(data)
    checkArg(1, data, "string")

    local uid = scheduler.activeThread()
    if uid == 1 or uid == nil then
        uid = "kernel"
    else
        uid = scheduler.info(uid).label or ("UID " .. uid)
    end

    if data:sub(-1) ~= "\n" then data = data .. "\n" end

    local clock = string.format("%.9f", os.clock())
    for line in data:gmatch("([^\n]*)\n") do
        push(string.format("[%s] [%s] : %s\n", clock, tostring(uid), line))
    end
end

return setmetatable({}, metatable)
