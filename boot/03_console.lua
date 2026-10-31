
-- Sets up console driver thing
_G.polaris.console = assert(
    dofile("/sys/drivers/console/init.lua"),
    "Console driver failed to initialize!"
)