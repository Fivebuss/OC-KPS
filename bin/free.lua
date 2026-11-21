-- /bin/free.lua
local total = computer.totalMemory()
local free  = computer.freeMemory()
local used  = total - free

for _, a in ipairs(args or {}) do
    if a == "--help" then
        io.writeln("Usage: free [-b] [-k] [-m] [-h] [-L]")
        io.writeln("Shows memory information, including that which has not been GC collected")
        io.writeln("  -b shows values in bytes (default)")
        io.writeln("  -k shows values in KiB")
        io.writeln("  -m shows values in MiB")
        io.writeln("  -h Human readable format")
        io.writeln("  -L shows everything on one line")
        os.exit(0)
    end
end

local flag = args and args[1] or nil

local function fmt(bytes)
    if not flag or flag == "-b" then
        return string.format("%d", bytes)
    elseif flag == "-k" then
        return string.format("%d", math.floor(bytes / 1024))
    elseif flag == "-m" then
        return string.format("%d", math.floor(bytes / 1048576))
    elseif flag == "-h" then
        if bytes >= 1048576 then
            return string.format("%.1fMiB", bytes / 1048576)
        elseif bytes >= 1024 then
            return string.format("%.1fKiB", bytes / 1024)
        else
            return string.format("%dB", bytes)
        end
    elseif flag == "-L" then
        return string.format("%d", bytes)
    else
        io.writelnError("free: invalid option: " .. flag)
        return nil
    end
end

local t = fmt(total)
if not t then return end
local u = fmt(used)
local f = fmt(free)

if flag == "-L" then
    io.writeln(string.format("Total: %s  Used: %s  Free: %s", t, u, f))
else
    io.writeln(string.format("%-8s %13s", "Total", t))
    io.writeln(string.format("%-8s %13s", "Used",  u))
    io.writeln(string.format("%-8s %13s", "Free",  f))
end