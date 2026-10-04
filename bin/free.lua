-- /bin/free.lua
local total = computer.totalMemory()
local free  = computer.freeMemory()
local used  = total - free

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
            return string.format("%.1fM", bytes / 1048576)
        elseif bytes >= 1024 then
            return string.format("%.1fK", bytes / 1024)
        else
            return string.format("%dB", bytes)
        end
    elseif flag == "-L" then
        return string.format("%d", bytes)
    else
        io.writelnError("free: invalid option: " .. flag)
        io.writelnError("usage: free [-b|-k|-m|-h|-L]")
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