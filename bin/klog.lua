-- /bin/klog.lua
-- Kernel log
local args = { ... }

for _, a in ipairs(args) do
    if a == "--help" then
        io.writeln("Usage: klog")
        io.writeln("Displays the polaris kernel log")
        os.exit(0)
    end
end

if #args > 1 then
    io.stderr:writeln("klog: too many arguements")
    os.exit(1)
elseif #args == 1 then
    polaris.log(tostring(args[1]))
else
    io.write(tostring(polaris.log))
end
