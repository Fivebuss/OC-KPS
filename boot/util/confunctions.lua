-- /boot/util/confunctions.lua
-- Initconsole functions

return {
    ping = function(cenv)
        console:write("pong\n")
    end,

    config = function(cenv)
        for k, v in pairs(cenv.config) do
            console:write(tostring(k), " = ", tostring(v), "\n")
        end
    end,

    debug = function(cenv)
        console:write("debug = ", tostring(cenv.debug) .. "\n")
    end,

    clear = function(cenv)
        cenv.console:clear()
    end,

    -- Poor mans ps
    threads = function(cenv)
        local tickInterval = polaris.config["interval"] or "Unknown"
        local infotable = cenv.process.list()

        console:write("Polaris process table:\nTick Interval: " ..
            tostring(tickInterval) .. "\nCount: " .. #infotable .. "\nInfo:\n")
        for _, t in ipairs(infotable) do
            console:write(
                string.format(
                    "PID=%s PPID=%s label=%s status=%s waiting=%s sleeping=%s cancelled=%s stopped=%s age=%.2f\n",
                    tostring(t.pid),
                    tostring(t.ppid),
                    tostring(t.cmd),
                    tostring(t.status),
                    tostring(t.waiting),
                    tostring(t.sleeping),
                    tostring(t.cancelled),
                    tostring(t.stopped),
                    t.age or 0
                )
            )
        end
    end,

    -- Gets _G so I can know if I missed anything
    env = function(cenv)
        local globalEnv = _G
        for key, value in pairs(globalEnv) do
            console:write(tostring(key) .. " = " .. tostring(value) .. "\n")
        end
    end,

    version = function(cenv)
        console:write(polaris.version.kernel .. "\n")
        console:write(polaris.version.os .. "\n")
    end,

    mounts = function(cenv)
        local filesystem = assert(require("filesystem"))
        for path, node in pairs(filesystem.fstab) do
            local fs = node.fs

            console:write(
                string.format(
                    "%-20s  %s\n",
                    path,
                    tostring(fs.address or "?")
                )
            )
        end
    end,

    -- Gets event handlers
    handlers = function(cenv)
        for id, handler in pairs(event.getHandlers()) do
            console:write(string.format(
                "[%d] key=%s callback=%s interval=%s times=%s next=%.3f\n",
                id,
                tostring(handler.key),
                tostring(handler.callback),
                tostring(handler.interval),
                tostring(handler.times),
                handler.timeout
            ))
        end
    end,


    shutdown = function(cenv)
        polaris.call("shutdown")
        --console:write("\n")
    end,

    reboot = function(cenv)
        polaris.call("reboot")
        --console:write("\n")
    end,

    clock = function(cenv)
        console:write(os.clock())
    end,

    log = function(cenv)
        console:write(tostring(polaris.log))
    end,

    modules = function(cenv)
        for index, module in pairs(polaris.loadedModules) do
            console:write(tostring(index) .. "  " .. tostring(module) .. "\n")
        end
    end,

    colors = function(cenv)
        local colors = {
            -- Foreground
            { 30, "Black" },
            { 31, "Red" },
            { 32, "Green" },
            { 33, "Yellow" },
            { 34, "Blue" },
            { 35, "Magenta" },
            { 36, "Cyan" },
            { 37, "White" },

            -- Bright
            { 90, "Bright Black" },
            { 91, "Bright Red" },
            { 92, "Bright Green" },
            { 93, "Bright Yellow" },
            { 94, "Bright Blue" },
            { 95, "Bright Magenta" },
            { 96, "Bright Cyan" },
            { 97, "Bright White" },

            -- Background
            { 40, "Black BG" },
            { 41, "Red BG" },
            { 42, "Green BG" },
            { 43, "Yellow BG" },
            { 44, "Blue BG" },
            { 45, "Magenta BG" },
            { 46, "Cyan BG" },
            { 47, "White BG" },
        }

        for _, color in ipairs(colors) do
            console:write(string.format("\27[%dm%s\27[0m\n", color[1], color[2]))
        end
    end,

    spawnTest = function(cenv)
        local process = polaris.process
        local function test()
            polaris.process.sleep(5)
            console:write("Finished\n")
        end
        local opts = {
            label = "Child Test",
            ppid = process.self(),
            pgid = process.GROUP.USERFG,
            onExit = function(success, err)
                console:write("Child onExit\n")
            end,
        }
        process.spawn(test, opts)
    end
}