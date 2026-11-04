-- /bin/sbedit.lua
-- it's kedit except with syntax highlighting and 20000x higher ram use
-- Courtesy of shedit, monokai theme (kinda)
-- No license for that but the author abandoned it and on forums was fine with others copying it so I think it's fine

-- I kinda need to put back the license
-- first modified 11/2/26 @ 9:42PM
-- Original text:

--[[
This edit is a simple text editor focusing entirely on speed.
It does not have bells and whistles.  Usage should be intuitive,
and more or less identical to OpenOS's editor.

Copyright (c) 2021 ULOS Developers under the GNU GPLv3.
]] --

local filesystem = require("filesystem")
local unicode = require("unicode")
local termio = require("termio")

local process = polaris.process

local UL, US = unicode.len, unicode.sub
local sformat, tconcat = string.format, table.concat

local args = args or {}

-- All the things
local buffer = { "" }
local curLine = 1
local curCol = 0
local scrollRow = 1
local hoffset = 0
local unsaved = false
local pendingQuit = false
local dirty = true
local cursorDirty = false
local lineDirty = false
local findMode = false
local findPromptDirty = false
local findPat = ""

if not ctty then
    io.writeError("sbedit: no controlling terminal")
    os.exit(1)
    return
end

if #args < 1 then
    io.writeError("usage: sbedit FILE")
    os.exit(1)
    return
end

local target = args[1]
if console and console.stripQuotes then
    target = console.stripQuotes(target)
end

local fullPath
if console and console.resolvePath and console.currPath then
    fullPath = console.resolvePath(console.currPath(), target)
elseif target:sub(1, 1) == "/" then
    fullPath = filesystem.canonical(target)
else
    fullPath = filesystem.concat("/", target)
end

local session = termio.open({ kind = "tty", tty = ctty })

local oldShape = ctty:getCursorShape()
local function size()
    local ok, w, h = pcall(session.getSize, session)
    if not ok or type(w) ~= "number" or w < 3 or type(h) ~= "number" or h < 4 then
        return 80, 25
    end
    return w, h
end

local function clip(str, n)
    if str == "" or n < 1 then return "" end
    local slen = UL(str)
    if slen <= n then return str end
    return US(str, 1, n)
end

local function sanitizeLine(line)
    return (line:gsub("\r", ""):gsub("\t", "  "))
end

local function restoreTerminal()
    pcall(function()
        if oldShape then session:setCursorShape(oldShape) end
    end)
    session:removeDiscipline()
    session:clearInput()
    session:write_str("\27[0m\27[2J\27[1;1H")
    session:flush()
end

local function doQuit()
    restoreTerminal()
    os.exit(0)
end

-- Stolen the coloration from shedit but made it 24-bit
local keywordColor = "\27[38;2;249;38;114m"
local commentColor = "\27[38;2;117;113;94m"
local stringColor = "\27[38;2;230;219;116m"
local valueColor = "\27[38;2;174;129;255m"
local builtinColor = "\27[38;2;102;217;239m"
local textColor = "\27[38;2;248;248;242m"
local resetColor = "\27[0m"

local keywords = {
    ['break'] = true,
    ['do'] = true,
    ['else'] = true,
    ['for'] = true,
    ['if'] = true,
    ['elseif'] = true,
    ['return'] = true,
    ['then'] = true,
    ['repeat'] = true,
    ['while'] = true,
    ['until'] = true,
    ['end'] = true,
    ['function'] = true,
    ['local'] = true,
    ['in'] = true,
    ['and'] = true,
    ['or'] = true,
    ['not'] = true,
    ['+'] = true,
    ['-'] = true,
    ['%'] = true,
    ['#'] = true,
    ['*'] = true,
    ['/'] = true,
    ['^'] = true,
    ['='] = true,
    ['=='] = true,
    ['~='] = true,
    ['<'] = true,
    ['<='] = true,
    ['>'] = true,
    ['>='] = true,
    ['..'] = true
}

local builtins = {
    ['assert'] = true,
    ['collectgarbage'] = true,
    ['dofile'] = true,
    ['error'] = true,
    ['getfenv'] = true,
    ['getmetatable'] = true,
    ['ipairs'] = true,
    ['loadfile'] = true,
    ['loadstring'] = true,
    ['module'] = true,
    ['next'] = true,
    ['pairs'] = true,
    ['pcall'] = true,
    ['print'] = true,
    ['rawequal'] = true,
    ['rawget'] = true,
    ['rawset'] = true,
    ['require'] = true,
    ['select'] = true,
    ['setfenv'] = true,
    ['setmetatable'] = true,
    ['tonumber'] = true,
    ['tostring'] = true,
    ['type'] = true,
    ['unpack'] = true,
    ['xpcall'] = true
}

local values = {
    ['false'] = true,
    ['nil'] = true,
    ['true'] = true,
    ['_G'] = true,
    ['_VERSION'] = true
}

local patterns = {
    { "^%-%-%[%[.-%]%]", commentColor },
    { "^%-%-.*",         commentColor },
    { "^\"\"",           stringColor },
    { "^\".-[^\\]\"",    stringColor },
    { "^\'\'",           stringColor },
    { "^\'.-[^\\]\'",    stringColor },
    { "^%[%[.-%]%]",     stringColor },
    { "^[%w_%+%-%%%#%*%/%^%=%~%<%>%.]+", function(text)
        if values[text] or tonumber(text) then
            return valueColor
        elseif keywords[text] then
            return keywordColor
        elseif builtins[text] then
            return builtinColor
        end
        return textColor
    end }
}

local highlightedBuffer = {}

-- This may cause ALOT of memory but it's fast so whatever
local function highlightLine(line)
    local result = {}
    local currentColor = textColor
    local segStart = 1
    local pos = 1
    local lineLen = #line

    while pos <= lineLen do
        local matched = false
        for i = 1, #patterns do
            local pat = patterns[i]

            local s, e = line:find(pat[1], pos)
            if s == pos and e and e >= pos then
                local matchedText = line:sub(s, e)
                local color = pat[2]
                if type(color) == "function" then
                    color = color(matchedText)
                end
                if pos > segStart then
                    result[#result + 1] = currentColor .. line:sub(segStart, pos - 1) .. resetColor
                    segStart = pos
                end
                result[#result + 1] = color .. matchedText .. resetColor
                segStart = e + 1
                pos = e + 1
                currentColor = textColor
                matched = true
                break
            end
        end
        if not matched then
            pos = pos + 1
        end
    end

    if segStart <= lineLen then
        result[#result + 1] = currentColor .. line:sub(segStart) .. resetColor
    end

    return table.concat(result)
end

-- Just for the horizontal area
local function highlightVisible(line)
    return highlightLine(clip(US(line, hoffset + 1), size()))
end

local function loadFile()
    if not filesystem.exists(fullPath) then
        highlightedBuffer = { highlightLine("") }
        return
    end

    if filesystem.isDirectory(fullPath) then
        io.writeError("sbedit: " .. target .. ": Is a directory")
        restoreTerminal()
        return false
    end

    local handle, why = io.open(fullPath, "rb")
    if not handle then
        io.writeError("sbedit: " .. target .. ": cannot open file: " .. tostring(why))
        restoreTerminal()
        return false
    end

    local chunks, count = {}, 0
    while true do
        local chunk = handle:read(2048)
        if not chunk or #chunk == 0 then break end
        count = count + 1
        chunks[count] = chunk

        local sig = coroutine.yield()
        if process.isSignal(sig) then
            handle:close()
            restoreTerminal()
            return false
        end
    end
    handle:close()

    local data = tconcat(chunks)
    local lines = {}
    local pos, n = 1, #data
    while pos <= n do
        local nl = data:find("\n", pos, true)
        if not nl then break end
        lines[#lines + 1] = sanitizeLine(data:sub(pos, nl - 1))
        pos = nl + 1
    end
    if pos <= n then
        lines[#lines + 1] = sanitizeLine(data:sub(pos))
    end
    if #lines == 0 then lines = { "" } end

    buffer = lines
    highlightedBuffer = {}
    for i = 1, #lines do
        highlightedBuffer[i] = highlightLine(lines[i])
    end
end

-- Wanna go?
local function getStatus()
    local w = size()

    local stat

    if findMode then
        stat = "find: " .. findPat .. "_"
    elseif pendingQuit then
        stat = "unsaved changes! really quit? [y/N]"
    else
        local name = filesystem.name(fullPath) or target or ""

        if UL(name) > 12 then
            name = US(name, UL(name) - 11, UL(name))
        end

        stat = sformat(
            "%s%s | L%d:C%d | ^W=quit ^S=save ^F=find",
            name,
            unsaved and "*" or "",
            curLine,
            curCol + 1
        )
    end

    -- Holy cow it jumps ALOT. GC working overtime
    local used = computer.totalMemory() - computer.freeMemory()
    local total = computer.totalMemory()
    local percent = total > 0 and (used / total * 100) or 0

    local mem = sformat("%d bytes used of %d : %.1f%%", used, total, percent)

    local available = math.max(0, w - UL(mem) - 2)
    stat = clip(stat, available)

    local result = stat .. string.rep(" ", math.max(0, w - 1 - UL(stat) - UL(mem))) .. mem

    return clip(result, w - 1)
end

-- Hey look, it's smarter now
local function updateCursor()
    local w, h = size()

    if curLine < scrollRow or curLine > scrollRow + h - 2 then
        dirty = true
        cursorDirty = false
        return
    end

    local row = curLine - scrollRow + 1
    local col = math.max(1, math.min(w, curCol - hoffset + 1))

    local out = {
        sformat(
            "\27[%d;1H\27[30;47m\27[K%s\27[0m",
            h,
            getStatus()
        ),

        sformat("\27[%d;%dH", row, col)
    }

    session:write_str(tconcat(out))
    session:flush()

    cursorDirty = false
end

-- And smarter here too
local function redrawLine()
    lineDirty = false
    local w, h = size()
    local row = curLine - scrollRow + 1

    if row < 1 or row > h - 1 then
        dirty = true
        return
    end
    local hl = highlightVisible(buffer[curLine] or "")
    local out = {
        string.format("\27[%d;1H%s\27[K", row, hl),
        string.format("\27[%d;1H\27[30;47m\27[K%s\27[0m", h, getStatus()),
        string.format("\27[%d;%dH", row, math.max(1, math.min(w, curCol - hoffset + 1))),
    }
    session:write_str(table.concat(out))
    session:flush()
end

-- Good lord this is laggy
local function redraw()
    dirty = false
    cursorDirty = false

    local w, h = size()

    if curLine < scrollRow then
        scrollRow = curLine
    elseif curLine > scrollRow + h - 2 then
        scrollRow = curLine - h + 2
    end

    if scrollRow < 1 then
        scrollRow = 1
    end

    local maxScroll = math.max(1, (#buffer + 1) - h + 2)

    if scrollRow > maxScroll then
        scrollRow = maxScroll
    end
    -- Horizontal
    if curCol - hoffset + 1 > w then
        hoffset = curCol - w + 1
    elseif curCol < hoffset then
        hoffset = math.max(0, curCol)
    end

    local out = {
        "\27[0m"
    }

    -- The text
    for row = 1, h - 1 do
        local ln = buffer[scrollRow + row - 1] or ""

        out[#out + 1] = sformat(
            "\27[%d;1H%s\27[K",
            row,
            highlightVisible(ln)
        )
    end

    -- Status bar
    out[#out + 1] = sformat(
        "\27[%d;1H\27[30;47m\27[K%s\27[0m",
        h,
        getStatus()
    )

    -- Cursor
    out[#out + 1] = sformat(
        "\27[%d;%dH",
        curLine - scrollRow + 1,
        math.max(1, math.min(w, curCol - hoffset + 1))
    )

    session:write_str(tconcat(out))
    session:flush()
end

-- It's seperate just so typing in it doesn't redraw entire screen...
local function redrawFindPrompt()
    local w, h = size()
    local prompt = "find: " .. findPat .. "_"
    local stat = clip(prompt, w - 1)

    session:write_str(
        sformat(
            "\27[0m\27[%d;1H\27[30;47m\27[K%s\27[0m",
            h,
            stat
        )
    )

    local col = math.min(w, UL("find: " .. findPat) + 1)
    session:write_str(sformat("\27[%d;%dH", h, col))
    session:flush()
end

local function statusFlash(msg)
    local w, h = size()
    msg = clip(msg, w - 1)
    session:write_str(sformat("\27[0m\27[%d;1H\27[30;47m\27[K%s\27[0m", h, msg))
    session:flush()
    process.sleep(0.9) -- gotta be a better way...
    dirty = true
end

local function splitLines(text)
    local out = {}
    local pos = 1
    while true do
        local nl = text:find("\n", pos, true)
        if not nl then break end
        out[#out + 1] = text:sub(pos, nl - 1)
        pos = nl + 1
    end
    out[#out + 1] = text:sub(pos)
    return out
end

local function insertChar(ch)
    local ln = buffer[curLine]
    local len = UL(ln)
    local head = (curCol > 0) and US(ln, 1, curCol) or ""
    local rest = (curCol < len) and US(ln, curCol + 1) or ""
    buffer[curLine] = head .. ch .. rest
    highlightedBuffer[curLine] = highlightLine(buffer[curLine])
    curCol = curCol + UL(ch)
    unsaved = true
    lineDirty = true
end
-- slow as hell
local function insertText(text)
    if not text or text == "" then return end

    local ln = buffer[curLine]
    local len = UL(ln)
    local head = (curCol > 0) and US(ln, 1, curCol) or ""
    local rest = (curCol < len) and US(ln, curCol + 1) or ""

    local full = head .. sanitizeLine(text) .. rest
    local parts = splitLines(full)

    buffer[curLine] = parts[1]
    highlightedBuffer[curLine] = highlightLine(parts[1])
    for i = 2, #parts do
        table.insert(buffer, curLine + i - 1, parts[i])
        table.insert(highlightedBuffer, curLine + i - 1, highlightLine(parts[i]))
    end

    if #parts > 1 then
        curLine = curLine + #parts - 1
    end
    curCol = UL(parts[#parts]) - UL(rest)
    if curCol < 0 then curCol = 0 end

    unsaved = true
    dirty = true
end

local function splitLine()
    local ln = buffer[curLine]
    local len = UL(ln)
    local tail = (curCol < len) and US(ln, curCol + 1) or ""

    buffer[curLine] = (curCol > 0) and US(ln, 1, curCol) or ""
    highlightedBuffer[curLine] = highlightLine(buffer[curLine])
    table.insert(buffer, curLine + 1, tail)
    table.insert(highlightedBuffer, curLine + 1, highlightLine(tail))

    curLine = curLine + 1
    curCol = 0
    unsaved = true
    dirty = true
end

local function backspace()
    local ln = buffer[curLine]
    local len = UL(ln)

    if curCol > 0 then
        local head = (curCol > 1) and US(ln, 1, curCol - 1) or ""
        local rest = (curCol < len) and US(ln, curCol + 1) or ""
        buffer[curLine] = head .. rest
        highlightedBuffer[curLine] = highlightLine(buffer[curLine])
        curCol = curCol - 1
        unsaved = true
        lineDirty = true
    elseif curLine > 1 then
        local prev = buffer[curLine - 1]
        local plen = UL(prev)
        table.remove(buffer, curLine)
        table.remove(highlightedBuffer, curLine)
        curLine = curLine - 1
        buffer[curLine] = prev .. ln
        highlightedBuffer[curLine] = highlightLine(buffer[curLine])
        curCol = plen
        unsaved = true
        dirty = true
    end
end
-- I should hope so
local function deleteForward()
    local ln = buffer[curLine]
    local len = UL(ln)

    if curCol < len then
        local head = (curCol > 0) and US(ln, 1, curCol) or ""
        local rest = (curCol + 1 < len) and US(ln, curCol + 2) or ""
        buffer[curLine] = head .. rest
        highlightedBuffer[curLine] = highlightLine(buffer[curLine])
        unsaved = true
        lineDirty = true
    elseif curLine < #buffer then
        buffer[curLine] = ln .. buffer[curLine + 1]
        highlightedBuffer[curLine] = highlightLine(buffer[curLine])
        table.remove(buffer, curLine + 1)
        table.remove(highlightedBuffer, curLine + 1)
        unsaved = true
        dirty = true
    end
end

local function curLineLen()
    if curLine > #buffer then return 0 end
    return UL(buffer[curLine])
end

local function clampCol()
    local len = curLineLen()
    if curCol > len then curCol = len end
end

local function ensureHorizontalScroll()
    local w = size()

    if curCol - hoffset + 1 > w then
        hoffset = curCol - w + 1
        dirty = true
    elseif curCol < hoffset then
        hoffset = curCol
        dirty = true
    end
end

local function moveLine(delta)
    local nl = curLine + delta

    if nl < 1 or nl > #buffer + 1 then
        return
    end

    if nl == curLine then
        return
    end

    curLine = nl
    clampCol()

    cursorDirty = true
end
local function moveCol(delta)
    local len = curLineLen()
    local nc = curCol + delta

    if nc < 0 then
        if curLine > 1 then
            curLine = curLine - 1
            curCol = curLineLen()
            cursorDirty = true
        end

        return
    end

    if nc > len then
        if curLine < #buffer + 1 then
            curLine = curLine + 1
            curCol = 0
            cursorDirty = true
        end

        return
    end

    if nc ~= curCol then
        curCol = nc
        cursorDirty = true
    end
end

local function movePage(dir)
    local _, h = size()

    local nl = math.max(
        1,
        math.min(#buffer, curLine + dir * math.max(1, h - 2))
    )
    if nl ~= curLine then
        curLine = nl
        clampCol()
        cursorDirty = true
    end
end

local function saveFile()
    local content = tconcat(buffer, "\n") .. "\n"

    local handle, why = filesystem.open(fullPath, "wb")
    if not handle then
        dirty = true
        return false, tostring(why)
    end

    local n, written, ok, reason = #content, 0
    local chunks = 0
    while written < n do
        local piece = content:sub(written + 1, math.min(n, written + 2048))
        ok, reason = handle:write(piece)
        if not ok then break end
        written = written + #piece
        chunks = chunks + 1
        if chunks % 8 == 0 then coroutine.yield() end
    end
    handle:close()

    if not ok then
        dirty = true
        return false, tostring(reason or "write failed")
    end

    unsaved = false
    dirty = true
    return true
end

local function byteToCol(ln, bytePos)
    if bytePos <= 1 then return 0 end
    return UL(ln:sub(1, bytePos - 1))
end
-- SLow? Sort of?
local function runFind()
    if findPat == "" then return end

    local function tryFind(ln, fromByte)
        local s = buffer[ln] or ""
        local ok, b = pcall(string.find, s, findPat, fromByte, false)
        if not ok or type(b) ~= "number" then
            ok, b = pcall(string.find, s, findPat, fromByte, true)
        end
        if ok and b then return b end
        return nil
    end

    local cl = buffer[curLine] or ""
    local cbyte = #US(cl, 1, curCol) + 1

    local hitLine, hitByte

    hitByte = tryFind(curLine, cbyte)
    if hitByte then hitLine = curLine end

    if not hitLine then
        for i = curLine + 1, #buffer do
            hitByte = tryFind(i, 1)
            if hitByte then
                hitLine = i
                break
            end
        end
    end

    if not hitLine then
        for i = 1, curLine - 1 do
            hitByte = tryFind(i, 1)
            if hitByte then
                hitLine = i
                break
            end
        end
    end

    if not hitLine and cbyte > 1 then
        hitByte = tryFind(curLine, 1)
        if hitByte then hitLine = curLine end
    end

    if hitLine then
        curLine = hitLine
        curCol = byteToCol(buffer[hitLine] or "", hitByte)
        hoffset = 0
        dirty = true
    else
        statusFlash("not found: " .. findPat)
    end
end

local function findKey(key)
    local char, code = key.char, key.code

    if char == 13 then
        findMode = false
        findPromptDirty = true
        runFind()
        return
    elseif char == 27 then
        findMode = false
        findPat = ""
        dirty = true
        return
    elseif char == 8 or char == 127 then
        local pl = UL(findPat)
        findPat = pl > 0 and US(findPat, 1, pl - 1) or ""
        findPromptDirty = true
        return
    end

    if (char == 0 and code ~= 0) or char == 3 or char == 23 or char == 19 then
        findMode = false
        findPat = ""
        dirty = true
        return "unhandled"
    end

    if char >= 32 and char <= 0x10FFFF
        and not (char >= 0xD800 and char <= 0xDFFF) then
        findPat = findPat .. (char > 255 and unicode.char or string.char)(char)
        findPromptDirty = true
    end
end

local keyQueue = {}
local queueHead = 1
local queueTail = 0

local disc = {}

function disc.onKeyDown(_, _, char, code)
    queueTail = queueTail + 1

    keyQueue[queueTail] = {
        char = char,
        code = code
    }

    return true
end

-- TTY usually handles this but not here
function disc.onClipboard(_, _, text)
    queueTail = queueTail + 1

    keyQueue[queueTail] = {
        text = text
    }

    return true
end

-- If spam
local function processKey(key)
    local char, code, text = key.char, key.code, key.text

    if text then
        pendingQuit = false
        if curLine <= #buffer then
            insertText(text)
        end
        return
    end

    if findMode then
        local routed = findKey(key)
        if routed ~= "unhandled" then return end
    end

    if pendingQuit then
        pendingQuit = false
        if char == 121 or char == 89 then
            return "quit"
        end
        dirty = true
        return
    end

    if char == 0 then
        if code == 200 then
            moveLine(-1)
        elseif code == 208 then
            moveLine(1)
        elseif code == 203 then
            moveCol(-1)
        elseif code == 205 then
            moveCol(1)
        elseif code == 199 then
            if curCol ~= 0 then
                curCol = 0
                cursorDirty = true
            end
        elseif code == 207 then
            local newCol = curLineLen()

            if curCol ~= newCol then
                curCol = newCol
                cursorDirty = true
            end
        elseif code == 201 then
            movePage(-1)
        elseif code == 209 then
            movePage(1)
        elseif code == 211 then
            if curLine <= #buffer then deleteForward() end
        end
        return
    end

    if char == 3 or char == 23 then
        if unsaved then
            pendingQuit = true
            dirty = true
        else
            return "quit"
        end
    elseif char == 19 then
        local ok, why = saveFile()
        if ok then
            statusFlash("saved")
        else
            statusFlash("save failed: " .. tostring(why))
        end
    elseif char == 6 then
        findMode = true
        findPat = ""
        dirty = true
    elseif char == 1 then
        if curCol ~= 0 then
            curCol = 0
            cursorDirty = true
        end
    elseif char == 5 then
        local newCol = curLineLen()

        if curCol ~= newCol then
            curCol = newCol
            cursorDirty = true
        end
    elseif char == 12 then
        dirty = true
    elseif curLine > #buffer then
        return
    elseif char == 13 then
        splitLine()
    elseif char == 8 then
        backspace()
    elseif char == 9 then
        insertChar("  ")
    elseif char == 4 then
        deleteForward()
    elseif char == 127 then
        deleteForward()
    elseif char == 26 then
    elseif char >= 32 and char <= 0x10FFFF
        and not (char >= 0xD800 and char <= 0xDFFF) then
        insertChar((char > 255 and unicode.char or string.char)(char))
    end

    return
end

session:clearInput()
session:setDiscipline(disc)
session:setCursorShape("invert")

session:write_str("\27[0m\27[2J\27[1;1H")
session:flush()

if loadFile() == false then
    os.exit(1)
    return
end
if buffer == nil then buffer = { "" } end
if highlightedBuffer == nil then highlightedBuffer = { highlightLine("") } end

-- Where the horrors happen
while true do
    local sig = coroutine.yield()

    if process.isSignal(sig) and sig == "INT" then
        doQuit()
        return
    end

    while queueHead <= queueTail do
        local key = keyQueue[queueHead]

        keyQueue[queueHead] = nil
        queueHead = queueHead + 1

        local acted = processKey(key)

        if acted == "quit" then
            doQuit()
            return
        end
    end

    if queueHead > queueTail then
        keyQueue = {}
        queueHead = 1
        queueTail = 0
    end

    ensureHorizontalScroll()

    if dirty then
        redraw()
        findPromptDirty = false
    elseif lineDirty then
        redrawLine()
        findPromptDirty = false
    elseif cursorDirty then
        updateCursor()
        findPromptDirty = false
    elseif findMode and findPromptDirty then
        redrawFindPrompt()
        findPromptDirty = false
    end
end
