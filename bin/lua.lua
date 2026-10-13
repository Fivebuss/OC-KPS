-- /bin/lua.lua
-- I just snatched openOS's kinda?

local serialization = require("serialization")
local filesystem = require("filesystem")
local unicode = require("unicode")

local function traceback(err)
    if debug and debug.traceback then
        return debug.traceback(tostring(err))
    end

    return tostring(err)
end

local function writeValue(value)
    local ok, result = pcall(serialization.serialize, value, true)

    if ok then
        io.writeln(result)
    else
        io.writeln(tostring(value))
    end
end

local function writeResults(result)
    for i = 2, result.n do
        writeValue(result[i])
    end
end

local function runChunk(chunk, ...)
    return table.pack(xpcall(function(...)
        return chunk(...)
    end, traceback, ...))
end

local function runFile(filename, fileArgs)
    local handle, reason = filesystem.open(filename, "r")

    if not handle then
        io.writelnError(
            "lua: could not open " ..
            tostring(filename) ..
            ": " ..
            tostring(reason)
        )
        return false
    end

    local chunks = {}
    while true do
        local chunk = handle:read(math.huge)
        if not chunk then break end
        chunks[#chunks + 1] = chunk
    end
    handle:close()
    local buffer = table.concat(chunks)

    if buffer == "" and #chunks == 0 then
        io.writelnError("lua: could not read " .. tostring(filename))
        return false
    end

    -- Remove a shebang if present.
    buffer = buffer:gsub("^#![^\n]*", "")

    local chunk, reason = load(
        buffer,
        "=" .. filename,
        "t",
        _ENV
    )

    if not chunk then
        io.writelnError(tostring(reason))
        return false
    end

    local result = runChunk(chunk, table.unpack(fileArgs))

    if not result[1] then
        io.writelnError(tostring(result[2]))
        return false
    end

    return true
end

-- Oh look, I can just steal my own readline
-- This is like a 1:1 copy practically

local function drawPrompt()
    ctty:write("\27[32mlua> \27[37m")
    ctty:flush()
end

local function utf8_chars(s)
    local i = 0
    return function()
        i = i + 1
        local c = unicode.sub(s, i, i)
        return c ~= "" and c or nil
    end
end

-- Mmmm ring buffers how I like you
local maxHisLen = polaris.config["ksh_history_length"] or 16
local history = { entries = {}, maxLen = maxHisLen }
local eofCount = 0

local function historyMaxLen()
    local v = polaris and polaris.config and polaris.config["ksh_history_length"]
    return (type(v) == "number" and v > 0) and math.floor(v) or maxHisLen
end

local function historyPush(line)
    if line == "" then return end
    local h = history.entries
    if h[#h] == line then return end
    h[#h + 1] = line
    local max = historyMaxLen()
    while #h > max do table.remove(h, 1) end
end

-- I hate OC clipboard handling. Its pure ass. So screw you, no multiline paste for anyone, it will remain broken
-- HORRIBLE readline this is genuinely abysmal but I need something
local function readline()
    local buf = {}
    local pos = 0
    local hIdx = nil
    local liveBuf = {}

    local function displayWidth(s)
        if unicode and unicode.wlen then
            return unicode.wlen(s)
        elseif unicode and unicode.len then
            return unicode.len(s)
        end
        return #s
    end

    local function moveCursorLeft(columns)
        if columns > 0 then
            ctty:write_str("\27[" .. columns .. "D")
        end
    end

    local function moveCursorRight(columns)
        if columns > 0 then
            ctty:write_str("\27[" .. columns .. "C")
        end
    end

    local function redrawLine()
        local line = table.concat(buf)
        local prompt = "\27[32mlua> \27[37m"

        ctty:write_str("\r" .. prompt .. line .. "\27[K")

        local suffix = table.concat(buf, "", pos + 1)
        moveCursorLeft(displayWidth(suffix))
    end

    local function resetHistoryNavigation()
        hIdx = nil
        liveBuf = { table.unpack(buf) }
    end

    local function replaceBuffer(text)
        buf = {}
        for c in utf8_chars(text) do
            buf[#buf + 1] = c
        end
        pos = #buf
    end

    local savedOnKeyDown = ctty.onKeyDown
    local savedClipboard = ctty.clipboard

    ctty.rb = ""
    drawPrompt()

    local resultLine = nil
    local done = false

    ctty.onKeyDown = function(self_tty, char, code)
        if done then return end
        -- Deal with delete
        if char == 127 then
            if pos > 0 then
                table.remove(buf, pos)
                pos = pos - 1
                resetHistoryNavigation()
                redrawLine()
            end

            return
        end

        -- Ok navigation
        if char == 0 then
            if code == 200 then -- Up arrow
                local h = history.entries
                if #h == 0 then return end

                if hIdx == nil then
                    liveBuf = { table.unpack(buf) }
                    hIdx = #h
                else
                    hIdx = math.max(1, hIdx - 1)
                end

                replaceBuffer(h[hIdx])
                redrawLine()
                return
            elseif code == 208 then -- Down arrow
                local h = history.entries
                if hIdx == nil then return end

                if hIdx >= #h then
                    hIdx = nil
                    buf = { table.unpack(liveBuf) }
                    pos = #buf
                else
                    hIdx = hIdx + 1
                    replaceBuffer(h[hIdx])
                end

                redrawLine()
                return
            elseif code == 203 then -- left arrow
                if pos > 0 then
                    local ch = buf[pos]
                    pos = pos - 1
                    moveCursorLeft(displayWidth(ch))
                end
                return
            elseif code == 205 then -- right arrow
                if pos < #buf then
                    local ch = buf[pos + 1]
                    pos = pos + 1
                    moveCursorRight(displayWidth(ch))
                end
                return
            elseif code == 211 then -- delete
                if pos < #buf then
                    table.remove(buf, pos + 1)
                    resetHistoryNavigation()
                    redrawLine()
                end
                return
            elseif code == 199 then -- home
                pos = 0
                redrawLine()
                return
            elseif code == 207 then -- end
                pos = #buf
                redrawLine()
                return
            end

            return
        end

        -- enter
        if char == 13 then
            resultLine = table.concat(buf)
            ctty:write_str("\n")
            done = true
            return
        end

        -- backspace
        if char == 8 then
            if pos > 0 then
                table.remove(buf, pos)
                pos = pos - 1
                resetHistoryNavigation()
                redrawLine()
            end
            return
        end

        -- CTRL A
        if char == 1 then
            pos = 0
            redrawLine()
            return
        end

        -- CTRL E
        if char == 5 then
            pos = #buf
            redrawLine()
            return
        end

        -- CTRL D
        if char == 4 then
            if #buf == 0 then
                eofCount = eofCount + 1
                resultLine = nil
                ctty:write_str("\n")
                done = true
            elseif pos < #buf then
                eofCount = 0
                table.remove(buf, pos + 1)
                resetHistoryNavigation()
                redrawLine()
            end
            return
        end

        eofCount = 0

        if char < 32 and char ~= 9 then
            savedOnKeyDown(self_tty, char, code)
            buf = {}
            pos = 0
            hIdx = nil
            liveBuf = {}
            resultLine = ""
            done = true
            return
        end

        -- Hey look invalid characters cant happen (in theory)
        if char < 0 or char > 0x10FFFF
            or (char >= 0xD800 and char <= 0xDFFF) then
            return
        end

        local ch = (char > 255 and unicode.char or string.char)(char)
        table.insert(buf, pos + 1, ch)
        pos = pos + 1
        resetHistoryNavigation()

        if pos == #buf then
            ctty:write_str(ch)
        else
            redrawLine()
        end
    end

    ctty.clipboard = function(self_tty, text)
        if done then return end

        text = text:gsub("\r\n", "\n"):gsub("\r", "\n")

        local pasted = {}
        for c in utf8_chars(text) do
            pasted[#pasted + 1] = c
        end

        for i = #pasted, 1, -1 do
            table.insert(buf, pos + 1, pasted[i])
        end

        pos = pos + #pasted
        resetHistoryNavigation()
        eofCount = 0

        local lineEnd = nil
        for i, c in ipairs(buf) do
            if c == "\n" then
                lineEnd = i
                break
            end
        end

        if lineEnd then
            resultLine = table.concat(buf, "", 1, lineEnd - 1)
            ctty:write_str("\n")
            done = true
            return
        end

        redrawLine()
    end

    while not done do
        coroutine.yield()
    end

    ctty.onKeyDown = savedOnKeyDown
    ctty.clipboard = savedClipboard
    ctty.rb = ""

    if resultLine == nil then return nil end
    historyPush(resultLine)
    return resultLine
end

local function repl()

    io.write("\27[37m" .. _VERSION .. " Copyright (C) 1994-2022 Lua.org, PUC-Rio\n")
    io.write("\27[93mEnter a statement and hit enter to evaluate it.\n")
    io.write("Prefix an expression with '=' to show its value.\n")
    io.write("Press Ctrl+D to exit the interpreter.\n\27[37m")

    -- Share the environment for the repl
    local replEnv = setmetatable({}, { __index = _ENV })

    local function stripLocal(cmd)
        local names, rest = cmd:match("^%s*local%s+([%a_][%w_%s,]-)%s*=(.+)$")
        if names then
            return names .. " =" .. rest
        end
        return cmd
    end

    while true do
        local command = readline()

        if not command then
            io.writeln()
            return
        end

        -- Ignore empty input.
        if command ~= "" then
            local code
            local reason

            if command:sub(1, 1) == "=" then
                code, reason = load(
                    "return " .. command:sub(2),
                    "=stdin",
                    "t",
                    replEnv
                )
            else
                -- maybe skip =
                local stripped = stripLocal(command)
                code, reason = load(
                    "return " .. stripped,
                    "=stdin",
                    "t",
                    replEnv
                )

                if not code then
                    code, reason = load(
                        stripped,
                        "=stdin",
                        "t",
                        replEnv
                    )
                end
            end

            if not code then
                io.writelnError(tostring(reason))
            else
                local result = runChunk(code)

                if not result[1] then
                    io.writelnError(tostring(result[2]))
                else
                    writeResults(result)
                end
            end
        end

        coroutine.yield()
    end
end

local args = args or {}

if #args == 0 then
    repl()
    return
end

local first = console.stripQuotes(args[1])
local extraArgs = {}

for i = 2, #args do
    extraArgs[#extraArgs + 1] = console.stripQuotes(args[i])
end

-- If it opens as a file, run it as a file; otherwise treat as a string to eval
local file = filesystem.open(first, "r")
if file then
    file:close()
    runFile(first, extraArgs)
else
    local chunk, reason = load(first, "=arg", "t", _ENV)
    if not chunk then
        io.writelnError(tostring(reason))
        return
    end
    local result = runChunk(chunk, table.unpack(extraArgs))
    if not result[1] then
        io.writelnError(tostring(result[2]))
    else
        writeResults(result)
    end
end
