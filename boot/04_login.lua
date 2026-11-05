-- Multi-user thing

if package.loaded["tty"] ~= nil then
    for gpu_addr in polaris.console.gpus() do
        dofile("/bin/login.lua", gpu_addr)
    end
else
    status("login shell failed to load: No tty")
end
