-- /bin/tail.lua
local filesystem = require("filesystem")
local process = polaris.process

local DEFAULT_LINES = 10
local READ_CHUNK_SIZE = 4096

local modeLines = true
local modeCount = DEFAULT_LINES
local fileArgs = {}

-- Support -n and -c
local function parseCount(value, option, original)
    local n = tonumber(value)

    if not n or n < 0 or n == math.huge or n ~= n then
        io.writelnError(
            "tail: invalid number of " .. option .. ": '" ..
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
            io.writelnError("tail: option requires an argument -- " .. a)
            os.exit(1)
        end

        setMode(a, args[i])

    elseif a:sub(1, 2) == "-n" or a:sub(1, 2) == "-c" then
        local option = a:sub(1, 2)
        setMode(option, a:sub(3))

    elseif a:sub(1, 1) == "-" then
        io.writelnError("tail: unknown option: " .. a)
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

-- This is problematic as a really bigass line can cause issues but its fine
local function tailLinesHandle(handle, count)
    if count == 0 then
        return
    end

    local lines = {}
    local total = 0

    local function saveLine(line)
        total = total + 1
        lines[((total - 1) % count) + 1] = line
    end

    local readLine

    if handle.readLine then
        readLine = function()
            return handle:readLine()
        end
    else
        local buffer = ""
        local eof = false

        readLine = function()
            while true do
                local newline = buffer:find("\n", 1, true)

                if newline then
                    local line = buffer:sub(1, newline)
                    buffer = buffer:sub(newline + 1)
                    return line
                end

                if eof then
                    if #buffer == 0 then
                        return nil
                    end

                    local line = buffer
                    buffer = ""
                    return line
                end

                local chunk = handle:read(READ_CHUNK_SIZE)

                if not chunk or #chunk == 0 then
                    eof = true
                else
                    buffer = buffer .. chunk
                end
            end
        end
    end

    while true do
        local line = readLine()

        if not line then
            break
        end

        if process.isSignal(line) then
            break
        end

        saveLine(line)

        if yield() then
            break
        end
    end

    local first = math.max(1, total - count + 1)

    for index = first, total do
        local line = lines[((index - 1) % count) + 1]

        if line and not io.write(line) then
            break
        end
    end
end

local function tailBytesHandle(handle, count)
    if count == 0 then
        return
    end

    local chunks = {}
    local totalBytes = 0
    local firstChunk = 1

    while true do
        local chunk = handle:read(READ_CHUNK_SIZE)

        if not chunk or #chunk == 0 then
            break
        end

        chunks[#chunks + 1] = chunk
        totalBytes = totalBytes + #chunk

        while totalBytes > count and firstChunk <= #chunks do
            local excess = totalBytes - count
            local first = chunks[firstChunk]

            if #first <= excess then
                totalBytes = totalBytes - #first
                chunks[firstChunk] = nil
                firstChunk = firstChunk + 1
            else
                chunks[firstChunk] = first:sub(excess + 1)
                totalBytes = count
            end
        end

        if yield() then
            break
        end
    end

    for j = firstChunk, #chunks do
        local chunk = chunks[j]

        if chunk and not io.write(chunk) then
            break
        end
    end
end

local function processStdin()
    if modeLines then

        local lines = {}
        local nextLine = 1

        while true do
            local line, _, noNewline = io.read("l")

            if not line then
                break
            end

            if process.isSignal(line) then
                break
            end

            local output = noNewline and line or (line .. "\n")

            if modeCount > 0 then
                lines[#lines + 1] = output

                if #lines - nextLine + 1 > modeCount then
                    lines[nextLine] = nil
                    nextLine = nextLine + 1
                end
            end

            if yield() then
                break
            end
        end

        for j = nextLine, #lines do
            if lines[j] and not io.write(lines[j]) then
                break
            end
        end
    else
        local chunks = {}
        local totalBytes = 0
        local firstChunk = 1

        while true do
            local chunk = io.read(READ_CHUNK_SIZE)

            if not chunk or #chunk == 0 then
                break
            end

            chunks[#chunks + 1] = chunk
            totalBytes = totalBytes + #chunk

            while totalBytes > modeCount and firstChunk <= #chunks do
                local excess = totalBytes - modeCount
                local first = chunks[firstChunk]

                if #first <= excess then
                    totalBytes = totalBytes - #first
                    chunks[firstChunk] = nil
                    firstChunk = firstChunk + 1
                else
                    chunks[firstChunk] = first:sub(excess + 1)
                    totalBytes = modeCount
                end
            end

            if yield() then
                break
            end
        end

        for j = firstChunk, #chunks do
            if chunks[j] and not io.write(chunks[j]) then
                break
            end
        end
    end

    io.flush()
end

-- This gave me weird issues
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
        io.writelnError("tail: " .. rawArg .. ": Is a directory")
        return false
    end

    local handle, reason = io.open(fullPath, "rb")

    if not handle then
        handle, reason = io.open(fullPath, "r")
    end

    if not handle then
        io.writelnError(
            "tail: " .. rawArg .. ": Cannot open file: " ..
            tostring(reason)
        )
        return false
    end

    local ok, err = pcall(function()
        if modeLines then
            tailLinesHandle(handle, modeCount)
        else
            tailBytesHandle(handle, modeCount)
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