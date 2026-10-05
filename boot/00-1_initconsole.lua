-- Starts init console if present and configures polaris.config

if polaris.config["initConsole"] == true then
    local package = require("package")
    if package.loaded["tty"] ~= nil then
        computer.beep(1000)
        dofile("/boot/util/initconsole.lua")
        console:write("Entering init console\n")
    else
        status("Initconsole failed to load: No tty")
    end
end
