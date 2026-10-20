-- Multi-user thing

if polaris.config["initConsole"] ~= true then
    if package.loaded["tty"] ~= nil then
        for gpu_addr in polaris.console.gpus() do
            polaris.console._spawnGpu = gpu_addr
            dofile("/bin/login.lua")
        end
        polaris.console._spawnGpu = nil
    else
        status("login shell failed to load: No tty")
    end
end
