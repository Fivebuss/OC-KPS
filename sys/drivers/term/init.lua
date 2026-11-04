-- /sys/drivers/term/init.lua
-- Terminal emulator essentially but it handles GPU stuff too
-- I split them because I plan for a pts/pty system soon and because its a good idea(?)
-- Most everything is just copy pasted from old tty

local unicode = require("unicode")
local computer = require("computer")
local term = {}

local len = unicode.len
local mmax, mmin = math.max, math.min
local sfind, ssub = string.find, string.sub

local color_profiles = {
    { 0x000000, 0xaa0000, 0x00aa00, 0xaa5500,
        0x0000aa, 0xaa00aa, 0x00aaaa, 0xaaaaaa,
        0x555555, 0xff5555, 0x55ff55, 0xffff55,
        0x5555ff, 0xff55ff, 0x55ffff, 0xffffff },
    { 0x232627, 0xed1515, 0x11d116, 0xf67400,
        0x1d99f3, 0x9b59b6, 0x1abc9c, 0xfcfcfc,
        0x7f8c8d, 0xc0392b, 0x1cdc9a, 0xfdbc4b,
        0x3daee9, 0x8e44ad, 0x16a085, 0xffffff },
    { 0x282828, 0xcc241d, 0x98971a, 0xd79921,
        0x458588, 0xb16286, 0x689d6a, 0xa89984,
        0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f,
        0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2 },
    { 0xfbf1c7, 0xcc241d, 0x98971a, 0xd79921,
        0x458588, 0xb16286, 0x689d6a, 0x7c6f64,
        0x928374, 0x9d0006, 0x79740e, 0xb57614,
        0x076678, 0x8f3f71, 0x427b58, 0x3c3836 },
    { 0xeeeeee, 0xaf0000, 0x008700, 0x5f8700,
        0x0087af, 0x878787, 0x005f87, 0x444444,
        0xbcbcbc, 0xd70000, 0xd70087, 0x8700af,
        0xd75f00, 0xd75f00, 0x005faf, 0x005f87 },
    { 0x292d3e, 0xf07178, 0xc3e88d, 0xffcb6b,
        0x82aaff, 0xc792ea, 0x89ddff, 0xd0d0d0,
        0x434758, 0xff8b92, 0xddffa7, 0xffe585,
        0x9cc4ff, 0xe1acff, 0xa3f7ff, 0xffffff },
    {
        0x000000,
        0xFF5555, 0x55FF55, 0xFFFF55,
        0x5555FF, 0xFF55FF, 0x55FFFF, 0xFFFFFF,
        0x888888,
        0xFF5555, 0x55FF55, 0xFFFF55,
        0x5555FF, 0xFF55FF, 0x55FFFF, 0xFFFFFF,
    },
}

-- I gotta replace config system some day...
local function cfg(key)
    return polaris and polaris.config and polaris.config[key]
end

-- Lol
local function brailleChar(a, b, c, d, e, f, g, h)
    return unicode.char(10240 + 128 * h + 64 * g + 32 * f + 16 * d + 8 * b + 4 * e + 2 * c + a)
end

local brailleGlyph = brailleChar(1, 1, 1, 1, 1, 1, 1, 1)
local cursorShapes = {
    invert = function() return nil end,
    block = function() return "█" end,
    braille = function() return brailleGlyph end,
    underline = function() return "▁" end,
    bar = function() return "▏" end,
}

local function pop(str, n, u)
    local sub, slen = string.sub, string.len
    if not u then
        sub = unicode.sub
        slen = unicode.len
    end
    local ret = sub(str, 1, n)
    local also = sub(str, slen(ret) + 1, -1)
    return also, ret
end

local syncCursor, wrapCursor, writeline, rawwrite, newLine, eraseCursor, drawCursor

local commands, control, dec = {}, {}, {}
local separators = { standard = "[", control = "?", dec = "[?" }

-- CTRL + ?
function commands.A(t, args)
    t.cy = t.cy - mmax(args[1] or 0, 1)
    wrapCursor(t)
end

function commands.B(t, args)
    t.cy = t.cy + mmax(args[1] or 0, 1)
    wrapCursor(t)
end

function commands.C(t, args)
    t.cx = t.cx + mmax(args[1] or 0, 1)
    wrapCursor(t)
end

function commands.D(t, args)
    t.cx = t.cx - mmax(args[1] or 0, 1)
    wrapCursor(t)
end

function commands.E(t, args)
    t.cy = t.cy + mmax(args[1] or 0, 1)
    t.cx = 1
    wrapCursor(t)
end

function commands.F(t, args)
    t.cy = t.cy - mmax(args[1] or 0, 1)
    t.cx = 1
    wrapCursor(t)
end

function commands.f(t, args)
    commands.H(t, args)
end

function commands.g(t, args)
    if #args < 1 then return end
    local cmd = table.remove(args, 1)
    if cmd == 0 then
        if #args < 4 then return end
        args[1] = mmax(1, mmin(args[1], t.w))
        args[2] = mmax(1, mmin(args[2], t.h))
        t.gpu.fill(args[1], args[2], args[3], args[4], " ")
    elseif cmd == 1 then
        if #args < 6 then return end
        t.cursorSaved = nil
        t.gpu.copy(args[1], args[2], args[3], args[4], args[5], args[6])
    end
end

function commands.G(t, args)
    t.cx = mmax(1, mmin(t.w, args[1] or 1))
end

function commands.H(t, args)
    local y, x = args[1] or 1, args[2] or 1
    t.cx = mmax(1, mmin(t.w, x))
    t.cy = mmax(1, mmin(t.h, y))
    wrapCursor(t)
end

function commands.J(t, args)
    local n = args[1] or 0
    if n == 0 then
        t.gpu.fill(1, t.cy, t.w, t.h - t.cy, " ")
    elseif n == 1 then
        t.gpu.fill(1, 1, t.w, t.cy, " ")
    elseif n == 2 then
        t.gpu.fill(1, 1, t.w, t.h, " ")
    end
end

function commands.K(t, args)
    local n = args[1] or 0
    if n == 0 then
        t.gpu.fill(t.cx, t.cy, t.w, 1, " ")
    elseif n == 1 then
        t.gpu.fill(1, t.cy, t.cx, 1, " ")
    elseif n == 2 then
        t.gpu.fill(1, t.cy, t.w, 1, " ")
    end
end

function commands.m(t, args)
    args[1] = args[1] or 0
    local i = 1
    while i <= #args do
        local n = args[i]
        if n == 0 then
            t.fg, t.bg, t.fgp, t.bgp = 7, 0, true, true
            t.gpu.setForeground(t.fg, true)
            t.gpu.setBackground(t.bg, true)
            t.attributes.echo = true
        elseif n == 8 then
            t.attributes.echo = false
        elseif n == 28 then
            t.attributes.echo = true
        elseif n > 29 and n < 38 then
            t.fg, t.fgp = n - 30, true
            t.gpu.setForeground(t.fg, true)
        elseif n == 39 then
            t.fg, t.fgp = 7, true
            t.gpu.setForeground(t.fg, true)
        elseif n > 39 and n < 48 then
            t.bg, t.bgp = n - 40, true
            t.gpu.setBackground(t.bg, true)
        elseif n == 49 then
            t.bg, t.bgp = 0, true
            t.gpu.setBackground(t.bg, true)
        elseif n > 89 and n < 98 then
            t.fg, t.fgp = n - 82, true
            t.gpu.setForeground(t.fg, true)
        elseif n > 99 and n < 108 then
            t.bg, t.bgp = n - 92, true
            t.gpu.setBackground(t.bg, true)
        elseif n == 38 or n == 48 then
            i = i + 1
            local mode = args[i]
            if mode == 2 then
                local r, g, b = args[i + 1], args[i + 2], args[i + 3]
                if b then
                    i = i + 3
                    local val = (r << 16) + (g << 8) + b
                    if n == 38 then
                        t.fg, t.fgp = val, false
                        t.gpu.setForeground(t.fg)
                    else
                        t.bg, t.bgp = val, false
                        t.gpu.setBackground(t.bg)
                    end
                end
            end
        end
        i = i + 1
    end
end

function commands.S(t, args)
    local n = args[1] or 1
    t.cursorSaved = nil
    t.gpu.copy(1, n, t.w, t.h, 0, -n)
    t.gpu.fill(1, t.h - n, t.w, n, " ")
end

function commands.T(t, args)
    local n = args[1] or 1
    t.cursorSaved = nil
    t.gpu.copy(1, 1, t.w, t.h - n, 0, n)
    t.gpu.fill(1, 1, t.w, n, " ")
end

function control.c(t, args)
    args[1] = args[1] or 0
    for i = 1, #args do
        local n = args[i]
        if n == 0 then
            t.attributes.echo, t.attributes.line = true, true
            t.attributes.raw, t.attributes.cursor = false, true
        elseif n == 1 then
            t.attributes.echo = true
        elseif n == 2 then
            t.attributes.line = true
        elseif n == 3 then
            t.attributes.raw = true
        elseif n == 4 then
            t.attributes.cursor = true
        elseif n == 5 then
            t.attributes.xoff = false
        elseif n == 11 then
            t.attributes.echo = false
        elseif n == 12 then
            t.attributes.line = false
        elseif n == 13 then
            t.attributes.raw = false
        elseif n == 14 then
            t.attributes.cursor = false
        elseif n == 15 then
            t.attributes.xoff = true
        end
    end
end

function control.s(t, args)
    args[1] = args[1] or 0
    for i = 1, #args do
        local n = args[i]
        if n == 0 then
            for k in pairs(t.disabled) do t.disabled[k] = nil end
        elseif n == 1 then
            t.disabled.C = true
        elseif n == 2 then
            t.disabled.Z = true
        elseif n == 3 then
            t.disabled.D = true
        elseif n == 11 then
            t.disabled.C = false
        elseif n == 12 then
            t.disabled.Z = false
        elseif n == 13 then
            t.disabled.D = false
        end
    end
end

function syncCursor(t)
    if t.cursor.follow then
        t.cursor.x, t.cursor.y = t.cx, t.cy
    end
end

function wrapCursor(t)
    while t.cx > t.w do
        t.cx, t.cy = mmax(1, t.cx - t.w), t.cy + 1
    end
    while t.cx < 1 do
        t.cx, t.cy = t.w + t.cx, t.cy - 1
    end
    while t.cy < 1 do
        t.cy = t.cy + 1
        t.cursorSaved = nil
        t.gpu.copy(1, 1, t.w, t.h - 1, 0, 1)
        t.gpu.fill(1, 1, t.w, 1, " ")
    end
    while t.cy > t.h do
        t.cy = t.cy - 1
        t.cursorSaved = nil
        t.gpu.copy(1, 2, t.w, t.h, 0, -1)
        t.gpu.fill(1, t.h, t.w, 1, " ")
    end
end

function newLine(t)
    t.cx, t.cy = 1, t.cy + 1
    wrapCursor(t)
    syncCursor(t)
end

function writeline(t, rline)
    local wrapped = false
    while #rline > 0 do
        local to_write
        rline, to_write = pop(rline, t.w - t.cx + 1)
        t.gpu.set(t.cx, t.cy, to_write)
        t.cx = t.cx + len(to_write)
        wrapped = t.cx > t.w
        wrapCursor(t)
    end
    return wrapped
end

function rawwrite(t, lines)
    if t.attributes.xoff then return end
    while #lines > 0 do
        local next_nl = sfind(lines, "\n", 1, true)
        if next_nl then
            local ln = ssub(lines, 1, next_nl - 1)
            lines = ssub(lines, next_nl + 1)
            local wrapped = writeline(t, ln)
            if not wrapped then
                t.cx, t.cy = 1, t.cy + 1
            end
            wrapCursor(t)
        else
            writeline(t, lines)
            break
        end
    end
end

-- Cursor handling fixed for multi-tty!
function eraseCursor(t)
    local saved = t.cursorSaved
    if not saved then return end

    t.cursorSaved = nil

    t.gpu.setForeground(saved.fg, saved.fgp)
    t.gpu.setBackground(saved.bg, saved.bgp)
    t.gpu.set(saved.x, saved.y, saved.char)

    t.gpu.setForeground(t.fg, t.fgp)
    t.gpu.setBackground(t.bg, t.bgp)
end

-- Could be simplified I think
function drawCursor(t)
    local cur = t.cursor
    if not cur.enabled or not cur.visible then return end

    local shapeFn = cursorShapes[cur.shape] or cursorShapes.invert
    local glyph = shapeFn()

    local c, f, b, pf, pb = t.gpu.get(cur.x, cur.y)

    local savedFg = pf ~= nil and pf or f
    local savedBg = pb ~= nil and pb or b
    local savedFgp = pf ~= nil
    local savedBgp = pb ~= nil

    local saved = t.cursorSaved
    if saved then
        saved.x, saved.y, saved.char = cur.x, cur.y, c
        saved.fg, saved.bg, saved.fgp, saved.bgp = savedFg, savedBg, savedFgp, savedBgp
    else
        t.cursorSaved = { x = cur.x, y = cur.y, char = c, fg = savedFg, bg = savedBg, fgp = savedFgp, bgp = savedBgp }
    end

    if glyph then
        t.gpu.setForeground(t.fg, t.fgp)
        t.gpu.setBackground(t.bg, t.bgp)
        t.gpu.set(cur.x, cur.y, glyph)
    else
        t.gpu.setForeground(savedBg, savedBgp)
        t.gpu.setBackground(savedFg, savedFgp)
        t.gpu.set(cur.x, cur.y, c)
    end

    t.gpu.setForeground(t.fg, t.fgp)
    t.gpu.setBackground(t.bg, t.bgp)
end

-- Kindly use console driver as this needs a provided gpu.
-- Or dont, once I add pts/pty
function term.new(gpu, disc)
    local attributes = disc and disc.attributes or
        { echo = true, line = true, raw = false, cursor = true, xoff = false }
    local disabled = disc and disc.disabled or {}

    local colors = {}
    for i, color in ipairs(color_profiles[1]) do
        colors[i] = color
    end
    if type(cfg("tty.profile")) == "number" then
        colors = color_profiles[cfg("tty.profile")] or color_profiles[1]
    end
    if type(cfg("tty.colors")) == "string" then
        for color in cfg("tty.colors"):gmatch("[^,]+") do
            local idx, col = color:match("(%x):(%x%x%x%x%x%x)")
            if idx and col then
                idx = tonumber(idx, 16) + 1
                colors[idx] = tonumber(col, 16) or colors[idx]
            end
        end
    end
    local originalColors = {}
    for i, color in ipairs(colors) do
        originalColors[i] = color
    end

    for i = 1, #colors do
        if gpu.setPaletteColor then
            gpu.setPaletteColor(i - 1, colors[i])
        end
    end

    if gpu.setDepth and gpu.maxDepth then
        gpu.setDepth(gpu.maxDepth())
    end

    local t = {
        gpu = gpu,
        disc = disc,
        attributes = attributes,
        disabled = disabled,

        inEsc = false,
        escBuf = "",
        cx = 1,
        cy = 1,

        cursor = {
            x = 1,
            y = 1,
            row = 1,
            col = 1,
            shape = "invert",
            enabled = true,
            visible = true,
            follow = true,
            blink = true,
            blinkOn = true,
        },

        fg = 7,
        bg = 0,
        fgp = true,
        bgp = true,
        cursorSaved = nil,
    }

    local originalFg = t.fg
    local originalBg = t.bg
    local originalFgp = t.fgp
    local originalBgp = t.bgp

    local function applyColors(colors)
        for i, color in ipairs(colors) do
            if t.gpu.setPaletteColor then
                t.gpu.setPaletteColor(i - 1, color)
            end
        end
    end

    gpu.setForeground(t.fg, true)
    gpu.setBackground(t.bg, true)

    t.w, t.h = gpu.getResolution()

    t.syncCursor = syncCursor
    t.wrapCursor = wrapCursor
    t.newLine = newLine
    t.eraseCursor = eraseCursor
    t.drawCursor = drawCursor

    function t:writeStr(str, isEcho)
        local gpu = self.gpu

        if self.attributes.cursor then
            eraseCursor(self)
        end

        str = str:gsub("[\t\a\r]", function(c)
            if c == "\t" then
                return "  "
            else
                return "\27[G"
            end
        end)

        while #str > 0 do
            if self.inEsc then
                local esc_end = str:find("[a-zA-Z]")
                if not esc_end then
                    self.escBuf = self.escBuf .. str
                    str = ""
                else
                    self.inEsc = false
                    local finish
                    str, finish = pop(str, esc_end, true)
                    local esc = self.escBuf .. finish
                    self.escBuf = ""

                    local separator, raw_args, code =
                        esc:match("\27(%[%?)([%d;]*)([a-zA-Z])")
                    if not separator then
                        separator, raw_args, code =
                            esc:match("\27([%[%?])([%-%d;]*)([a-zA-Z])") -- Fixed
                    end
                    raw_args = raw_args or "0"
                    local args = {}
                    for arg in raw_args:gmatch("([^;]+)") do
                        args[#args + 1] = tonumber(arg) or 0
                    end

                    if separator == separators.dec and dec[code] then
                        dec[code](self, args)
                    elseif separator == separators.standard and commands[code] then
                        commands[code](self, args)
                    elseif separator == separators.control and control[code] then
                        control[code](self, args)
                    end
                    wrapCursor(self)
                    syncCursor(self)
                end
            else
                local next_esc = sfind(str, "\27", 1, true)
                if next_esc then
                    self.inEsc = true
                    self.escBuf = ""
                    local ln
                    str, ln = pop(str, next_esc - 1, true)
                    rawwrite(self, ln)
                else
                    rawwrite(self, str)
                    str = ""
                end
            end
        end

        syncCursor(self)

        local disc = self.disc
        if not isEcho and disc and #disc.rb > 0 and disc.attributes.echo and not disc.attributes.raw then
            rawwrite(self, disc.rb)
            wrapCursor(self)
            syncCursor(self)
        end

        if self.attributes.cursor then
            drawCursor(self)
        end

        return true
    end

    function t:clear()
        self.gpu.fill(1, 1, self.w, self.h, " ")
        self.cx, self.cy = 1, 1
        self.cursorSaved = nil
        syncCursor(self)
    end

    function t:resetColors()
        -- Restore pallete
        applyColors(originalColors)

        -- Restore fg/bg
        self.fg = originalFg
        self.bg = originalBg
        self.fgp = originalFgp
        self.bgp = originalBgp

        -- Apply
        self.gpu.setForeground(self.fg, self.fgp)
        self.gpu.setBackground(self.bg, self.bgp)
    end

    -- Finally supported
    function t:setResolution(w, h)
        if self.attributes.cursor then eraseCursor(self) end
        local ok = self.gpu.setResolution(w, h)
        if not ok then
            if self.attributes.cursor then drawCursor(self) end
            return false
        end
        self.w, self.h = w, h
        self.cx, self.cy = 1, 1
        self.cursorSaved = nil
        self.gpu.fill(1, 1, self.w, self.h, " ")
        syncCursor(self)
        if self.attributes.cursor then drawCursor(self) end
        return true
    end

    -- Cursor stuff
    function t:setCursorShape(shape)
        if self.attributes.cursor then eraseCursor(self) end
        self.cursor.shape = cursorShapes[shape] and shape or "invert"
        if self.attributes.cursor then drawCursor(self) end
    end

    function t:getCursorShape()
        return self.cursor.shape
    end

    function t:registerCursorShape(name, fn)
        cursorShapes[name] = fn
    end

    function t:setCursorPos(x, y)
        if self.attributes.cursor then eraseCursor(self) end
        self.cursor.follow = false
        self.cursor.x, self.cursor.y = x, y
        if self.attributes.cursor then drawCursor(self) end
    end

    function t:setCursorRowCol(row, col, toScreen)
        self.cursor.row, self.cursor.col = row, col
        if toScreen then
            local x, y = toScreen(row, col)
            self:setCursorPos(x, y)
        end
    end

    function t:setCursorFollow(enabled)
        self.cursor.follow = enabled ~= false
        if self.cursor.follow then
            syncCursor(self)
        end
    end

    function t:setCursorVisible(visible)
        if self.attributes.cursor then eraseCursor(self) end
        self.cursor.visible = visible ~= false
        if self.attributes.cursor and self.cursor.visible then drawCursor(self) end
    end

    function t:getCursorVisible()
        return self.cursor.visible
    end

    function t:setCursor(enabled)
        enabled = enabled ~= false
        if self.attributes.cursor and not enabled then eraseCursor(self) end
        self.attributes.cursor = enabled
        self.cursor.enabled = enabled
        if enabled then drawCursor(self) end
    end

    function t:getCursor()
        return self.attributes.cursor
    end

    function t:setCursorBlink(enabled)
        self.cursor.blink = enabled ~= false
        if not self.cursor.blink then
            self.cursor.blinkOn = true
            if self.attributes.cursor then eraseCursor(self) end
            self.cursor.visible = true
            if self.attributes.cursor then drawCursor(self) end
        end
    end

    function t:tickBlink()
        if not self.cursor.blink then return end

        local disc = self.disc
        local inputActive = disc and disc.lastInput
            and computer.uptime() - disc.lastInput < 0.5
        if inputActive then
            if not self.cursor.blinkOn then
                self.cursor.blinkOn = true

                if self.attributes.cursor then
                    eraseCursor(self)
                    self.cursor.visible = true
                    drawCursor(self)
                end
            end
            return
        end
        self.cursor.blinkOn = not self.cursor.blinkOn
        if self.attributes.cursor then eraseCursor(self) end
        self.cursor.visible = self.cursor.blinkOn
        if self.attributes.cursor and self.cursor.visible then
            drawCursor(self)
        end
    end

    return t
end

return term
