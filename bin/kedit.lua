-- /bin/kedit.lua
-- a hopefully fast editor. Thanks ULOS. I made some major changes however
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

-- State
local buffer = { "" }
local curLine = 1
local curCol = 0
local scrollRow = 1 -- first visible line
local hoffset = 0
local unsaved = false
local pendingQuit = false
local dirty = true
local findMode = false
local findPat = ""

-- Thank goodness for _G.ctty
if not ctty then
    io.writeError("kedit: no controlling terminal")
    os.exit(1)
    return
end

if #args < 1 then
    io.writeError("usage: kedit FILE")
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

local session = termio.open({ tty = ctty })

local oldShape
pcall(function()
    if ctty.getCursorShape then oldShape = ctty:getCursorShape() end
end)

local function size()
    local ok, w, h = pcall(session.getSize, session)
    if not ok or type(w) ~= "number" or w < 3 or type(h) ~= "number" or h < 4 then
        return 80, 25
    end
    return w, h
end

-- Clip a line to n unicode chars
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
    -- I think this is supported
    session:write_str("\27[0m\27[2J\27[1;1H")
    session:flush()
end

local function doQuit()
    restoreTerminal()
    os.exit(0)
end

local function loadFile()
    if not filesystem.exists(fullPath) then
        return
    end

    if filesystem.isDirectory(fullPath) then
        io.writeError("kedit: " .. target .. ": Is a directory")
        restoreTerminal()
        return false
    end

    local handle, why = io.open(fullPath, "rb")
    if not handle then
        io.writeError("kedit: " .. target .. ": cannot open file: " .. tostring(why))
        restoreTerminal()
        return false
    end

    -- Il chunk read
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

    -- Splitting
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
end

-- Drawing. Oh boy

local function redraw()
    dirty = false

    local w, h = size()

    -- Hey! dont go outside the window
    if curLine < scrollRow then
        scrollRow = curLine
    elseif curLine > scrollRow + h - 2 then
        scrollRow = curLine - h + 2
    end
    if scrollRow < 1 then scrollRow = 1 end
    -- +1
    local maxScroll = math.max(1, (#buffer + 1) - h + 2)
    if scrollRow > maxScroll then scrollRow = maxScroll end

    if curCol - hoffset + 1 > w then
        hoffset = curCol - w + 1
    elseif curCol < hoffset then
        hoffset = math.max(0, curCol)
    end

    local out = { "\27[0m" }

    for row = 1, h - 1 do
        local ln = buffer[scrollRow + row - 1] or ""
        local piece = ""
        if ln ~= "" and hoffset < UL(ln) then
            piece = clip(US(ln, hoffset + 1), w)
        end
        out[#out + 1] = sformat("\27[%d;1H%s\27[K", row, piece)
    end

    -- Status bar
    local stat
    if findMode then
        stat = "find: " .. findPat .. "_"
    elseif pendingQuit then
        stat = "unsaved changes! really quit? [y/N]"
    else
        local name = filesystem.name(fullPath) or target or ""
        if UL(name) > 12 then
            name = US(name, UL(name) - 11, UL(name)) or name
        end
        stat = sformat("%s%s | L%d:C%d | ^W=quit ^S=save ^F=find",
            name, unsaved and "*" or "", curLine, curCol + 1)
    end
    stat = clip(stat, w - 1)

    out[#out + 1] = sformat("\27[%d;1H\27[30;47m\27[K%s\27[0m", h, stat)

    out[#out + 1] = sformat("\27[%d;%dH",
        curLine - scrollRow + 1,
        math.max(1, math.min(w, curCol - hoffset + 1)))

    session:write_str(tconcat(out))
    session:flush()
end

-- Good lord but this copies
local function statusFlash(msg)
    local w, h = size()
    msg = clip(msg, w - 1)
    session:write_str(sformat("\27[0m\27[%d;1H\27[30;47m\27[K%s\27[0m", h, msg))
    session:flush()
    process.sleep(0.9)
    dirty = true
end

-- actually editing

-- Does what it says
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
    curCol = curCol + UL(ch)
    unsaved = true
    dirty = true
end

local function insertText(text)
    if not text or text == "" then return end

    local ln = buffer[curLine]
    local len = UL(ln)
    local head = (curCol > 0) and US(ln, 1, curCol) or ""
    local rest = (curCol < len) and US(ln, curCol + 1) or ""

    local full = head .. sanitizeLine(text) .. rest
    local parts = splitLines(full)

    buffer[curLine] = parts[1]
    for i = 2, #parts do
        table.insert(buffer, curLine + i - 1, parts[i])
    end

    if #parts > 1 then
        curLine = curLine + #parts - 1
    end
    -- Cursor lands after the inserted text
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
    table.insert(buffer, curLine + 1, tail)

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
        curCol = curCol - 1
        unsaved = true
        dirty = true
    elseif curLine > 1 then
        -- join with the previous line
        local prev = buffer[curLine - 1]
        local plen = UL(prev)
        table.remove(buffer, curLine)
        curLine = curLine - 1
        buffer[curLine] = prev .. ln
        curCol = plen
        unsaved = true
        dirty = true
    end
end

local function deleteForward()
    local ln = buffer[curLine]
    local len = UL(ln)

    if curCol < len then
        local head = (curCol > 0) and US(ln, 1, curCol) or ""
        local rest = (curCol + 1 < len) and US(ln, curCol + 2) or ""
        buffer[curLine] = head .. rest
        unsaved = true
        dirty = true
    elseif curLine < #buffer then
        buffer[curLine] = ln .. buffer[curLine + 1]
        table.remove(buffer, curLine + 1)
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

local function moveLine(delta)
    local nl = curLine + delta

    if nl < 1 or nl > #buffer + 1 then
        return
    end

    curLine = nl
    clampCol()
    dirty = true
end

local function moveCol(delta)
    local len = curLineLen()
    local nc = curCol + delta

    if nc < 0 then
        -- off the left edge: wrap up to the previous line's end
        if curLine > 1 then
            curLine = curLine - 1
            curCol = curLineLen()
            dirty = true
        end
        return
    end

    if nc > len then
        if curLine < #buffer + 1 then
            curLine = curLine + 1
            curCol = 0
            dirty = true
        end
        return
    end

    if nc ~= curCol then
        curCol = nc
        dirty = true
    end
end

local function movePage(dir)
    local _, h = size()
    local nl = math.max(1, math.min(#buffer, curLine + dir * math.max(1, h - 2)))
    if nl ~= curLine then
        curLine = nl
        clampCol()
        dirty = true
    end
end

-- Save
local function saveFile()
    local content = tconcat(buffer, "\n") .. "\n"

    -- Man I really need io.open
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
        -- Hey! Stop hogging cpu!
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

-- ^F which does some outrageous work

local function byteToCol(ln, bytePos)
    if bytePos <= 1 then return 0 end
    return UL(ln:sub(1, bytePos - 1))
end

-- This is HORRIFIC
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

    -- Order is ridiculous
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

-- return "unhandled" if the key should fall through to normal editing
local function findKey(key)
    local char, code = key.char, key.code

    if char == 13 then -- enter: go
        findMode = false
        dirty = true
        runFind()
        return
    elseif char == 27 then -- escape
        findMode = false
        findPat = ""
        dirty = true
        return
    elseif char == 8 or char == 127 then -- backspace / delete on the prompt
        local pl = UL(findPat)
        findPat = pl > 0 and US(findPat, 1, pl - 1) or ""
        dirty = true
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
        dirty = true
    end
end

-- Input time

local keyQueue = {}

local disc = {}

function disc.onKeyDown(_, _, char, code)
    if #keyQueue < 16 then
        keyQueue[#keyQueue + 1] = { char = char, code = code }
    end
    return true
end

function disc.onClipboard(_, _, text)
    if #keyQueue < 32 then
        keyQueue[#keyQueue + 1] = { text = text }
    end
    return true
end

local function processKey(key)
    local char, code, text = key.char, key.code, key.text

    -- Paste
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
        if char == 121 or char == 89 then -- y / Y
            return "quit"
        end
        dirty = true
        return
    end

    if char == 0 then
        if code == 200 then     -- up
            moveLine(-1)
        elseif code == 208 then -- down
            moveLine(1)
        elseif code == 203 then -- left
            moveCol(-1)
        elseif code == 205 then -- right
            moveCol(1)
        elseif code == 199 then -- home
            curCol = 0
            dirty = true
        elseif code == 207 then -- end
            curCol = UL(buffer[curLine])
            dirty = true
        elseif code == 201 then -- pgup
            movePage(-1)
        elseif code == 209 then -- pgdn
            movePage(1)
        elseif code == 211 then -- delete
            if curLine <= #buffer then deleteForward() end
        end
        return
    end

    -- Everything else
    if char == 3 or char == 23 then -- ^C / ^W quit
        if unsaved then
            pendingQuit = true
            dirty = true
        else
            return "quit"
        end
    elseif char == 19 then -- ^S
        local ok, why = saveFile()
        if ok then
            statusFlash("saved")
        else
            statusFlash("save failed: " .. tostring(why))
        end
    elseif char == 6 then -- ^F
        findMode = true
        findPat = ""
        dirty = true
    elseif char == 1 then -- ^A jump to start of line
        curCol = 0
        dirty = true
    elseif char == 5 then -- ^E jump to end of line
        curCol = curLineLen()
        dirty = true
    elseif char == 12 then -- ^L
        dirty = true
    elseif curLine > #buffer then
        return
    elseif char == 13 then  -- enter
        splitLine()
    elseif char == 8 then   -- backspace
        backspace()
    elseif char == 9 then   -- tab
        insertChar("  ")
    elseif char == 4 then   -- ^D delete forward
        deleteForward()
    elseif char == 127 then -- delete
        deleteForward()
    elseif char == 26 then  -- ^Z
        -- nope
    elseif char >= 32 and char <= 0x10FFFF
        and not (char >= 0xD800 and char <= 0xDFFF) then
        insertChar((char > 255 and unicode.char or string.char)(char))
    end

    return
end

-- The rest

-- Get off my screen
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

while true do
    local sig = coroutine.yield()
    if process.isSignal(sig) and sig == "INT" then
        doQuit()
        return
    end

    while #keyQueue > 0 do
        local key = table.remove(keyQueue, 1)
        local acted = processKey(key)
        if acted == "quit" then
            doQuit()
            return
        end
    end

    if dirty then
        redraw()
    end
end
