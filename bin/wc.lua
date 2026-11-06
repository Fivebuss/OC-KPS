-- /bin/wc.lua
-- not much to say really, alot is just copy paste code
local filesystem = require("filesystem")
local getopt = require("ksh.getopt")
local process = polaris.process

local showLines = false
local showBytes = false
local showChars = false
local showWords = false

local args = { ... }

-- -c bytes -m chars -w words -l lines
for opt, val in getopt(args, "lcmw", {}) do
    if opt == "l" then
        showLines = true
    elseif opt == "c" then
        showBytes = true
    elseif opt == "m" then
        showChars = true
    elseif opt == "w" then
        showWords = true
    elseif opt == "?" then
        io.writelnError("wc: unrecognized option '" .. tostring(val) .. "'")
        os.exit(1)
        return
    end
end

if not showLines and not showBytes and not showChars and not showWords then
    showLines = true
    showWords = true
    showBytes = true
end

-- hopefully(?) multi file support
local targets = {}
for _, arg in ipairs(args) do
    if arg ~= "-" then
        table.insert(targets, console.resolvePath(console.currPath(), console.stripQuotes(arg)))
    else
        table.insert(targets, "-")
    end
end

if #targets == 0 then
    table.insert(targets, "-")
end

-- cheap trick so it isnt loop hell
local function countData(data)
    local bytes = #data
    local _, lines = data:gsub("\n", "")
    local _, words = data:gsub("%S+", "")
    return lines, words, bytes, bytes
end

-- Its different for performance reasons mostly
local function processStdin()
    local totalLines = 0
    local totalWords = 0
    local totalBytes = 0
    local totalChars = 0

    local stdinInfo = require("io").describeStream(io.stdin)

    if stdinInfo.kind == "pipe" then
        local chunkSize = 4096
        local chunkCount = 0
        local chunk = io.stdin:read(chunkSize)

        while chunk do
            if process.isSignal(chunk) then break end

            local lines, words, bytes, chars = countData(chunk)
            totalLines = totalLines + lines
            totalWords = totalWords + words
            totalBytes = totalBytes + bytes
            totalChars = totalChars + chars

            chunkCount = chunkCount + 1
            if chunkCount % 4 == 0 then
                coroutine.yield()
            end

            chunk = io.stdin:read(chunkSize)
        end
    else
        local lineCount = 0
        while true do
            local line, _, noNewline = io.read("l")
            if not line then break end

            if process.isSignal(line) then break end

            local data = noNewline and line or (line .. "\n")
            local lines, words, bytes, chars = countData(data)
            totalLines = totalLines + lines
            totalWords = totalWords + words
            totalBytes = totalBytes + bytes
            totalChars = totalChars + chars

            lineCount = lineCount + 1
            if lineCount % 64 == 0 then
                coroutine.yield()
            end
        end
    end

    return totalLines, totalWords, totalBytes, totalChars
end

-- See above. Performance
local function processFile(target)
    if not filesystem.exists(target) then
        io.writelnError("wc: " .. target .. ": No such file or directory")
        return nil, nil, nil, nil
    end

    if filesystem.isDirectory(target) then
        io.writelnError("wc: " .. target .. ": Is a directory")
        return nil, nil, nil, nil
    end

    local handle, reason = io.open(target, "rb")
    if not handle then
        io.writelnError("wc: " .. target .. ": " .. tostring(reason))
        return nil, nil, nil, nil
    end

    local totalLines = 0
    local totalWords = 0
    local totalBytes = 0
    local totalChars = 0

    local chunkSize = 4096
    local chunkCount = 0
    local chunk = handle:read(chunkSize)

    while chunk do
        local lines, words, bytes, chars = countData(chunk)
        totalLines = totalLines + lines
        totalWords = totalWords + words
        totalBytes = totalBytes + bytes
        totalChars = totalChars + chars

        chunkCount = chunkCount + 1
        if chunkCount % 4 == 0 then
            coroutine.yield()
        end

        chunk = handle:read(chunkSize)
    end

    handle:close()

    return totalLines, totalWords, totalBytes, totalChars
end

-- total but louder
local grandTotalLines = 0
local grandTotalWords = 0
local grandTotalBytes = 0
local grandTotalChars = 0
local fileCount = 0

-- Do the thing
for _, target in ipairs(targets) do
    local lines, words, bytes, chars
    if target == "-" then
        lines, words, bytes, chars = processStdin()
    else
        lines, words, bytes, chars = processFile(target)
    end

    if lines then
        local output = ""
        if showLines then output = output .. string.format("%8d", lines) end
        if showWords then output = output .. string.format("%8d", words) end
        if showChars then output = output .. string.format("%8d", chars) end
        if showBytes then output = output .. string.format("%8d", bytes) end
        if target ~= "-" then
            output = output .. " " .. target
        end
        io.writeln(output)

        grandTotalLines = grandTotalLines + lines
        grandTotalWords = grandTotalWords + words
        grandTotalBytes = grandTotalBytes + bytes
        grandTotalChars = grandTotalChars + chars
        fileCount = fileCount + 1
    end
    coroutine.yield()
end

if fileCount > 1 then
    local output = ""
    if showLines then output = output .. string.format("%8d", grandTotalLines) end
    if showWords then output = output .. string.format("%8d", grandTotalWords) end
    if showChars then output = output .. string.format("%8d", grandTotalChars) end
    if showBytes then output = output .. string.format("%8d", grandTotalBytes) end
    output = output .. " total"
    io.writeln(output)
end
