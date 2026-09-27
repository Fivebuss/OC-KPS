-- Starts ksh

if polaris.config["initConsole"] ~= true then
    if package.loaded["tty"] ~= nil then
        dofile("/bin/ksh.lua")
    else
        status("ksh failed to load: No tty")
    end
end
