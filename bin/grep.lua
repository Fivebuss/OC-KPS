-- /bin/grep.lua
-- Ported from Wobbo's. Though it uses text library where it can
-- Very straightforward port. I did like 2% of what is here

local filesystem = require("filesystem")
local getopt = require("ksh.getopt")
local process = polaris.process
local text = require("text")

-- Specify the variables for the options
local plain = false
local count = false
local ignoreCase = false
local writeNamesOnce = false
local lineNumber = false
local quiet = false
local fileError = true
local invert = false
local matchWhole = false
local printNames = false
local onlyMatching = false  -- -o
local extendedRegex = false -- -E we will just cheat

-- Table with patterns to check for
local patternList = {}

-- Table with files to look in
local patternFiles = {}

local function printUsage()
    io.writelnError('Usage: grep [-c|-l|-q][-EFinsvxo] [-e pattern] [-f patternFile] [pattern] [file...]')
end

-- Resolve the location of a file, without searching the path
local function resolve(file)
    console.resolvePath(console.currPath(), file)
end

-- Checks if it should error, and errors if that is required
local function fileErrorFunc(file)
    if fileError then
        io.writelnError("grep: " .. file .. ": No such file or directory")
    end
end

--- Builds a case insensitive pattern, code from stackOverflow (questions/11401890/case-insensitive-lua-pattern-matching)
local function caseInsensitivePattern(pattern)
    -- find an optional '%' (group 1) followed by any character (group 2)
    local p = pattern:gsub("(%%?)(.)", function(percent, letter)
        if percent ~= "" or not letter:match("%a") then
            -- if the '%' matched, or `letter` is not a letter, return "as is"
            return percent .. letter
        else
            -- else, return a case-insensitive character class of the matched letter
            return string.format("[%s%s]", letter:lower(), letter:upper())
        end
    end)
    return p
end

-- Process the command line arguments
local args = { ... }
if #args < 1 then
    printUsage()
    os.exit(2)
end

for opt, arg in getopt(args, "EFce:f:ilnqsvxo") do
    if opt == 'F' then
        plain = true
    elseif opt == 'c' then
        if writeNamesOnce or quiet then
            printUsage()
            os.exit(2)
        end
        count = true
    elseif opt == 'e' then
        table.insert(patternList, arg)
    elseif opt == 'f' then
        table.insert(patternFiles, arg)
    elseif opt == 'i' then
        ignoreCase = true
    elseif opt == 'l' then
        if count or quiet then
            printUsage()
            os.exit(2)
        end
        writeNamesOnce = true
    elseif opt == 'n' then
        lineNumber = true
    elseif opt == 'q' then
        if writeNamesOnce or count then
            printUsage()
            os.exit(2)
        end
        quiet = true
    elseif opt == 's' then
        fileError = false
    elseif opt == 'v' then
        invert = true
    elseif opt == 'x' then
        matchWhole = true
    elseif opt == 'o' then
        onlyMatching = true
    elseif opt == 'E' then
        extendedRegex = true
    elseif opt == '?' then
        printUsage()
        os.exit(2)
    elseif opt == ':' then
        io.writelnError(opt .. ' needs an argument!')
        printUsage()
        os.exit(2)
    end
end

-- Split on |
local function splitEREPattern(pat)
    local parts = {}
    local current = ""
    local inClass = false
    local i = 1
    while i <= #pat do
        local c = pat:sub(i, i)
        if c == "[" and not inClass then
            inClass = true
            current = current .. c
        elseif c == "]" and inClass then
            inClass = false
            current = current .. c
        elseif c == "|" and not inClass then
            if #current > 0 then
                table.insert(parts, current)
            end
            current = ""
        else
            current = current .. c
        end
        i = i + 1
    end
    if #current > 0 then
        table.insert(parts, current)
    end
    return parts
end

-- Read the pattern files and add the patterns to the patternList
for i = 1, #patternFiles do
    local file = resolve(patternFiles[i])
    if filesystem.exists(file) then
        local handle = io.open(file, 'r')
        if handle then
            for pat in handle:lines() do
                table.insert(patternList, pat)
            end
            handle:close()
        end
    else
        fileErrorFunc(file)
    end
end

-- Check if there are patterns, if not, get args[1] and add it to the list
if #patternList == 0 then
    if #args < 1 then
        printUsage()
        os.exit(2)
    else
        table.insert(patternList, table.remove(args, 1))
    end
end

-- I like how I do extendedRegex then dont support it
if extendedRegex then
    local newPatternList = {}
    for _, pat in ipairs(patternList) do
        local parts = splitEREPattern(pat)
        for _, p in ipairs(parts) do
            table.insert(newPatternList, p)
        end
    end
    patternList = newPatternList
end

-- Prepare an iterator for reading files
local readLines
if #args >= 1 then
    readLines = function()
        local files = args
        local curHand = nil
        local curFile = nil
        local curLineNum = 0
        return function()
            if not curFile and #files > 0 then
                local rawFile = table.remove(files, 1)
                file = resolve(rawFile)
                if filesystem.exists(file) then
                    curFile = file
                    curHand = io.open(curFile, 'r')
                    if lineNumber then curLineNum = 1 end
                else
                    fileErrorFunc(file)
                    return false, "file not found"
                end
            end
            if not curHand then
                return nil
            end
            local line = curHand:read("*l")
            if not line then
                curFile = nil
                curHand:close()
                curHand = nil
                if #files < 1 then
                    return nil
                else
                    return false, "end of file"
                end
            else
                local currentLineNum = curLineNum
                if lineNumber then curLineNum = curLineNum + 1 end
                return line, curFile, currentLineNum
            end
        end
    end
else
    readLines = function()
        local lineNum = 0
        return function()
            local line = io.read("*l")
            if not line then return nil end
            lineNum = lineNum + 1
            return line, '(standard input)', lineNum
        end
    end
end

-- Main
if #args > 1 then printNames = true end

local matchFile = nil
local lineCount = 0

for line, file, ln in readLines() do
    local sig = coroutine.yield()
    if sig == "INT" then os.exit(130) end
    if process.isSignal(sig) then break end

    if not line then
        if file ~= "end of file" then os.exit(2) end
    else
        file = file or '(standard input)'
        local match = false
        local matches = {}
        for _, pattern in pairs(patternList) do
            local pat = pattern
            if ignoreCase then pat = caseInsensitivePattern(pattern) end
            if onlyMatching then
                -- -o support
                local pos = 1
                while pos <= #line do
                    local i, j = line:find(pat, pos, plain)
                    if not i then break end
                    matches[#matches + 1] = line:sub(i, j)
                    pos = j + 1
                    if pos > #line then break end
                end
                match = #matches > 0
            else
                local i, j = line:find(pat, 1, plain)
                if not matchWhole then
                    match = i and true or match
                else
                    if j == #line and i == 1 then match = true end
                end
            end
        end
        if match ~= invert then
            if quiet then os.exit(0) end
            if not count then
                if writeNamesOnce then
                    if matchFile ~= file then io.writeln(file) end
                else
                    if onlyMatching then
                        for _, m in ipairs(matches) do
                            local out = ""
                            if printNames then out = file .. ': ' end
                            if lineNumber then out = out .. ln .. ': ' end
                            out = out .. m
                            io.writeln(out)
                        end
                    else
                        local out = ""
                        if printNames then out = file .. ': ' end
                        if lineNumber then out = out .. ln .. ': ' end
                        out = out .. line
                        io.writeln(out)
                    end
                end
            elseif matchFile ~= file then
                if printNames then io.write(matchFile .. ': ') end
                io.writeln(lineCount)
                lineCount = 1
            else
                lineCount = lineCount + 1
            end
            matchFile = file
        end
    end
end

if count and matchFile then
    if printNames then io.write(matchFile .. ': ') end
    io.writeln(lineCount)
end

os.exit(matchFile and 0 or 1)
