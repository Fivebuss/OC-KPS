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
        local count = cenv.scheduler.threadCount() or "Unknown"
        local active = cenv.scheduler.activeThread() or "Unknown"
        local tickInterval = polaris.scheduler.interval or "Unknown"
        local infotable = cenv.scheduler.list()

        console:write("Polaris scheduler:\nTick Interval: " ..
            tickInterval .. "\nCount: " .. count .. "\nactive thread uid: " .. active .. "\nInfo:\n")
        for _, t in ipairs(infotable) do
            console:write(
                string.format(
                    "UID=%s label=%s status=%s waiting=%s sleeping=%s cancelled=%s stopped=%s age=%.2f\n",
                    tostring(t.uid),
                    t.label,
                    t.status,
                    tostring(t.waiting),
                    tostring(t.sleeping),
                    tostring(t.cancelled),
                    tostring(t.stopped),
                    t.age
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
        local i = 0
        for handler in pairs(event.getHandlers()) do
            i = i + 1
            console:write(string.format(
                "[%d] callback=%s interval=%s times=%s next=%.3f\n",
                i,
                tostring(handler.callback),
                tostring(handler.interval),
                tostring(handler.times),
                handler.nextTriggerTime
            ))
        end
    end,

    shutdown = function(cenv)
        polaris.call("shutdown")
        console:write("\n")
    end,

    assert = function(cenv)
        assert(false)
    end,
}
