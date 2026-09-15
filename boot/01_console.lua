-- Starts ksh

if polaris.config["initConsole"] ~= true then
    if package.loaded["sys.kernel.modules.tty"] ~= nil then
        dofile("/bin/ksh.lua")
    else
        status("ksh failed to load: No tty")
    end
end
