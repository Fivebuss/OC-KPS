
-- Sets up console driver thing
_G.polaris.console = assert(
    dofile("/sys/drivers/console/init.lua"),
    "Console driver failed to initialize!"
)

if package.loaded["tty"] ~= nil then
    for gpu_addr in polaris.console.gpus() do
        dofile("/bin/login.lua", gpu_addr)
    end
else
    status("login shell failed to load: No tty")
end
