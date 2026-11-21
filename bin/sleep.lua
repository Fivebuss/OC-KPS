-- /bin/sleep.lua
-- Thank goodness this can be far easier
local args = {...}

for _, a in ipairs(args) do
    if a == "--help" then
        io.writeln("Usage: sleep NUMBER[SUFFIX]...")
        io.writeln("Sleep for NUMBER seconds, an integer or floating-point number")
        io.writeln("Suffix may be 's','m','h,'d' for seconds, minutes, hours, and days")
        io.writeln("Accepts multiple numbers and combines them")
        io.writeln("Why would you want to sleep for days? Are you unemployed?")
        os.exit(0)
    end
end

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
