-- /bin/head.lua
local filesystem = require("filesystem")
local process = polaris.process

local DEFAULT_LINES = 10
local READ_CHUNK_SIZE = 4096

local modeLines = true
local modeCount = DEFAULT_LINES
local fileArgs = {}


-- il support -n and -c
local function parseCount(value, option, original)
    local n = tonumber(value)

    if not n or n < 0 or n == math.huge or n ~= n then
        io.writelnError(
            "head: invalid number of " .. option .. ": '" ..
            tostring(original) .. "'"
        )
        os.exit(1)
    end

    return math.floor(n)
end

local function setMode(option, value)
    if option == "-n" then
        modeLines = true
        modeCount = parseCount(value, "lines", value)
    else
        modeLines = false
        modeCount = parseCount(value, "bytes", value)
    end
end

local i = 1

while i <= #args do
    local a = args[i]

    if a == "--" then
        for j = i + 1, #args do
            fileArgs[#fileArgs + 1] = args[j]
        end
        break

    elseif a == "-n" or a == "-c" then
        i = i + 1

        if i > #args then
            io.writelnError("head: option requires an argument -- " .. a)
            os.exit(1)
        end

        setMode(a, args[i])

    elseif a:sub(1, 2) == "-n" or a:sub(1, 2) == "-c" then
        local option = a:sub(1, 2)
        setMode(option, a:sub(3))

    elseif a:sub(1, 1) == "-" then
        io.writelnError("head: unknown option: " .. a)
        os.exit(1)

    else
        fileArgs[#fileArgs + 1] = a
    end

    i = i + 1
end

local function printHeader(name)
    io.write("==> " .. name .. " <==\n")
    io.flush()
end

local function yield()
    local sig = coroutine.yield()
    return sig and process.isSignal(sig)
end

local function headBytesHandle(handle, remaining)
    while remaining > 0 do
        local chunk = handle:read(math.min(READ_CHUNK_SIZE, remaining))

        if not chunk or #chunk == 0 then
            break
        end

        if not io.write(chunk) then
            break
        end

        remaining = remaining - #chunk

        if remaining > 0 and yield() then
            break
        end
    end
end

local function lineReader(handle)
    local buffer = ""
    local pos = 1
    local eof = false
    local parts = {}

    return function()
        while true do
            local newline = buffer:find("\n", pos, true)

            if newline then
                parts[#parts + 1] = buffer:sub(pos, newline)
                local line = table.concat(parts)
                parts = {}

                pos = newline + 1
                return line
            end

            if pos <= #buffer then
                parts[#parts + 1] = buffer:sub(pos)
            end

            buffer = ""
            pos = 1

            if eof then
                if #parts == 0 then
                    return nil
                end

                local line = table.concat(parts)
                parts = {}
                return line
            end

            local chunk = handle:read(READ_CHUNK_SIZE)

            if not chunk or #chunk == 0 then
                eof = true
            else
                buffer = chunk
            end
        end
    end
end

local function linesHandle(handle, remaining)
    local readLine

    if handle.readLine then
        readLine = function()
            return handle:readLine()
        end
    else
        readLine = lineReader(handle)
    end

    while remaining > 0 do
        local line = readLine()

        if not line then
            break
        end

        if process.isSignal(line) then
            break
        end

        if not io.write(line) then
            break
        end

        remaining = remaining - 1

        if remaining > 0 and yield() then
            break
        end
    end
end

local function processStdin()
    local remaining = modeCount

    if modeLines then
        while remaining > 0 do
            local line, _, noNewline = io.read("l")

            if not line then
                break
            end

            if process.isSignal(line) then
                break
            end

            local output = noNewline and line or (line .. "\n")

            if not io.write(output) then
                break
            end

            remaining = remaining - 1

            if remaining > 0 and yield() then
                break
            end
        end
    else
        while remaining > 0 do
            local chunk = io.read(math.min(READ_CHUNK_SIZE, remaining))

            if not chunk or #chunk == 0 then
                break
            end

            if not io.write(chunk) then
                break
            end

            remaining = remaining - #chunk

            if remaining > 0 and yield() then
                break
            end
        end
    end

    io.flush()
end

-- File support
local function processFile(rawArg)
    if rawArg == "-" then
        processStdin()
        return true
    end

    local target = console and console.stripQuotes(rawArg) or rawArg
    local fullPath = console
        and console.resolvePath(console.currPath(), target)
        or target

    if filesystem.isDirectory(fullPath) then
        io.writelnError("head: " .. rawArg .. ": Is a directory")
        return false
    end

    local handle, reason = io.open(fullPath, "rb")

    if not handle then
        handle, reason = io.open(fullPath, "r")
    end

    if not handle then
        io.writelnError(
            "head: " .. rawArg .. ": Cannot open file: " ..
            tostring(reason)
        )
        return false
    end

    local ok, err = pcall(function()
        if modeLines then
            linesHandle(handle, modeCount)
        else
            headBytesHandle(handle, modeCount)
        end

        io.flush()
    end)

    handle:close()

    if not ok then
        error(err, 0)
    end

    return true
end

if #fileArgs == 0 then
    processStdin()
else
    local hasError = false
    local multiFile = #fileArgs > 1

    for _, arg in ipairs(fileArgs) do
        if multiFile then
            local label = arg == "-" and "standard input" or arg
            printHeader(label)
        end

        if not processFile(arg) then
            hasError = true
        end

        if multiFile then
            io.write("\n")
            io.flush()
        end
    end

    if hasError then
        os.exit(1)
    end
end