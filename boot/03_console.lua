
-- Sets up console driver thing
_G.polaris.console = assert(
    dofile("/sys/drivers/console/init.lua"),
    "Console driver failed to initialize!"
)

-- polaris.config["tty.profile"] = 1
-- polaris.config["ksh_history_length"] = 32

-- if polaris.config["initConsole"] ~= true then
--     if package.loaded["tty"] ~= nil then
--         for gpu_addr in polaris.console.gpus() do
--             polaris.console._spawnGpu = gpu_addr
--             dofile("/bin/ksh.lua")
--         end
--         polaris.console._spawnGpu = nil
--     else
--         status("ksh failed to load: No tty")
--     end
-- end