-- Extending functionality for stuff
local scheduler = polaris.scheduler
-- Search by prefix
function package.loadedNames(prefix)
    checkArg(1, prefix, "string")

    local result = {}

    for name in pairs(package.loaded) do
        if name == prefix or name:sub(1, #prefix + 1) == prefix .. "." then
            table.insert(result, name)
        end
    end

    return result
end

polaris.loadedModules = package.loadedNames("sys")

-- Replace os.sleep
function os.sleep(n)
    checkArg(1, n, "number")
    if polaris.scheduler.currentThread() then
        polaris.scheduler.sleep(seconds)
    else
        error("os.sleep called outside a scheduler thread")
    end

    return true
end

-- os.exit
function os.exit(code)
    if code == nil or code < 0 or code > 255 then
        code = 0
    end
    scheduler.exit(code)
end

function os.execute(command)
    return "os.execute not implemented kernel-level"
end
