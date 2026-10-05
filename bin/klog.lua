-- /bin/klog.lua
-- Kernel log
local args = { ... }

if #args > 1 then
    io.stderr:writeln("klog: too many arguements")
    os.exit(1)
    return false
elseif #args == 1 then
    polaris.log(tostring(args[1]))
else
    io.write(tostring(polaris.log))
end
