-- /bin/sleep.lua
-- Thank goodness this can be far easier
local process = require("process")
local args = {...}

local units = {
    s = 1,
    m = 60,
    h = 3600,
    d = 86400,
}

local total = 0

for i = 1, #args do
    local value = args[i]
    local n, suffix = value:match("^([%d%.]+)([smhd]?)$")

    if not n then
        io.stderr:writeln("sleep: invalid time interval: " .. value)
        os.exit(1)
        break
    end

    if suffix == "" then
        suffix = "s"
    end

    total = total + tonumber(n) * units[suffix]
end

process.sleep(total)
