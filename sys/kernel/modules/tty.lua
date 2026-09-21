-- /sys/kernel/modules/tty.lua
--
-- Ported from cynosure. Because it is the best tty library I have used

local unicode = require("unicode")
local event = require("sys.kernel.modules.event")
local io = require("sys.kernel.modules.io")
local computer = require("computer")

-- Process does it's job
local process = polaris.process

local tty = {}

-- I did change palletes tho

local color_profiles = {
    { -- default VGA colors
        0x000000, 0xaa0000, 0x00aa00, 0xaa5500,
        0x0000aa, 0xaa00aa, 0x00aaaa, 0xaaaaaa,
        0x555555, 0xff5555, 0x55ff55, 0xffff55,
        0x5555ff, 0xff55ff, 0x55ffff, 0xffffff
    },
    { -- Breeze theme colors from Konsole
        0x232627, 0xed1515, 0x11d116, 0xf67400,
        0x1d99f3, 0x9b59b6, 0x1abc9c, 0xfcfcfc,
        0x7f8c8d, 0xc0392b, 0x1cdc9a, 0xfdbc4b,
        0x3daee9, 0x8e44ad, 0x16a085, 0xffffff
    },
    { -- Gruvbox
        0x282828, 0xcc241d, 0x98971a, 0xd79921,
        0x458588, 0xb16286, 0x689d6a, 0xa89984,
        0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f,
        0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2
    },
    { -- Gruvbox light
        0xfbf1c7, 0xcc241d, 0x98971a, 0xd79921,
        0x458588, 0xb16286, 0x689d6a, 0x7c6f64,
        0x928374, 0x9d0006, 0x79740e, 0xb57614,
        0x076678, 0x8f3f71, 0x427b58, 0x3c3836
    },
    { -- PaperColor light
        0xeeeeee, 0xaf0000, 0x008700, 0x5f8700,
        0x0087af, 0x878787, 0x005f87, 0x444444,
        0xbcbcbc, 0xd70000, 0xd70087, 0x8700af,
        0xd75f00, 0xd75f00, 0x005faf, 0x005f87
    },
    { -- Pale Night
        0x292d3e, 0xf07178, 0xc3e88d, 0xffcb6b,
        0x82aaff, 0xc792ea, 0x89ddff, 0xd0d0d0,
        0x434758, 0xff8b92, 0xddffa7, 0xffe585,
        0x9cc4ff, 0xe1acff, 0xa3f7ff, 0xffffff,
    },
    {             -- MShell pallete
        0x000000, -- black              Background
        0xFF5555, -- red                Error
        0x55FF55, -- green              Success
        0xFFFF55, -- yellow             Warning
        0x5555FF, -- blue
        0xFF55FF, -- magenta
        0x55FFFF, -- cyan               Info
        0xFFFFFF, -- white              Text
        0x888888, -- gray               Other info/dim
        0xFF5555, -- bright red
        0x55FF55, -- bright green
        0xFFFF55, -- bright yellow
        0x5555FF, -- bright blue
        0xFF55FF, -- bright magenta
        0x55FFFF, -- bright cyan
        0xFFFFFF, -- bright white
    },
}

local len = unicode.len
local usub = unicode.sub

local function brailleChar(a, b, c, d, e, f, g, h)
    return unicode.char(10240 + 128 * h + 64 * g + 32 * f + 16 * d + 8 * b + 4 * e + 2 * c + a)
end

-- Snatched my glyph renderer trick
local cursorShapes = {
    invert = function() return nil end,
    block = function() return "█" end,
    braille = function() return brailleChar(1, 1, 1, 1, 1, 1, 1, 1) end,
    underline = function() return "▁" end,
    bar = function() return "▏" end,
}

-- From front pop
local function pop(str, n, u)
    local sub, slen = string.sub, string.len
    if not u then
        sub = unicode.sub; slen = unicode.len
    end
    local ret = sub(str, 1, n)
    local also = sub(str, slen(ret) + 1, -1)
    return also, ret
end

-- Uses my own scheduler

-- Internal tty characters
local sigacts = {
    D = true,       -- ^D eof
    C = "INT",      -- ^C int
    Z = "TSTP",     -- ^Z
    ["/"] = "KILL", -- ^\ quit
}

-- Uses polaris.config instead

local function cfg(key)
    return polaris and polaris.config and polaris.config[key]
end


function tty.new(gpu)
    local self = {
        gpu = gpu,

        attributes = { echo = true, line = true, raw = false, cursor = true, xoff = false },
        disabled = {},     -- Disabled signal handling
        attachedUids = {}, -- Owners
        onSignal = nil,    -- Shells job

        in_esc = false,
        esc = "",
        cx = 1,
        cy = 1,

        -- Cursor is now a proper table, x/y/row/col are seperate for readline shenanigans
        cursor = {
            x = 1,
            y = 1,
            row = 1,
            col = 1,
            shape = "invert",
            enabled = true,
            visible = true,
            follow = true,  -- if true x/y follows cx/cy
            blink = true,
            blinkOn = true, -- Is it on?
        },

        fg = 7,
        bg = 0,
        fgp = true,
        bgp = true,
        rb = "", -- input read buffer
        wb = "", -- output line-buffering buffer
    }

    -- Palette selection, ported from cmdline to polaris.config
    local colors = color_profiles[1]
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

    for i = 1, #colors do
        if gpu.setPaletteColor then
            gpu.setPaletteColor(i - 1, colors[i])
        end
    end

    if gpu.setDepth and gpu.maxDepth then
        gpu.setDepth(gpu.maxDepth())
    end

    gpu.setForeground(self.fg, true)
    gpu.setBackground(self.bg, true)

    self.w, self.h = gpu.getResolution()

    -- Sure helps to have this i/o library
    self.reader, self.writer = io.newPipeEndpoints(polaris.process)

    -- Utils are basically 1:1

    -- Remove snapshot of contents
    local function removeCshot(t)
        t.cursorSaved = nil
    end
    self.removeCshot = removeCshot

    local function wrap_cursor(t)
        while t.cx > t.w do
            t.cx, t.cy = math.max(1, t.cx - t.w), t.cy + 1
        end
        while t.cx < 1 do
            t.cx, t.cy = t.w + t.cx, t.cy - 1
        end
        while t.cy < 1 do
            t.cy = t.cy + 1
            removeCshot(t)
            t.gpu.copy(1, 1, t.w, t.h - 1, 0, 1)
            t.gpu.fill(1, 1, t.w, 1, " ")
        end
        while t.cy > t.h do
            t.cy = t.cy - 1
            removeCshot(t)
            t.gpu.copy(1, 2, t.w, t.h, 0, -1)
            t.gpu.fill(1, t.h, t.w, 1, " ")
        end
    end
    self.wrap_cursor = wrap_cursor

    -- Duh
    local function syncCursor(t)
        if t.cursor.follow then
            t.cursor.x, t.cursor.y = t.cx, t.cy
        end
    end
    self.syncCursor = syncCursor

    local function writeline(t, rline)
        local wrapped = false
        while #rline > 0 do
            local to_write
            rline, to_write = pop(rline, t.w - t.cx + 1)
            t.gpu.set(t.cx, t.cy, to_write)
            t.cx = t.cx + len(to_write)
            wrapped = t.cx > t.w
            wrap_cursor(t)
        end
        return wrapped
    end

    local function rawwrite(t, lines)
        if t.attributes.xoff then return end
        while #lines > 0 do
            local next_nl = lines:find("\n")
            if next_nl then
                local ln
                lines, ln = pop(lines, next_nl - 1, true)
                lines = lines:sub(2)
                local wrapped = writeline(t, ln)
                if not wrapped then
                    t.cx, t.cy = 1, t.cy + 1
                end
                wrap_cursor(t)
            else
                writeline(t, lines)
                break
            end
        end
    end

    -- Same for ansi stuff

    local commands, control = {}, {}
    local separators = { standard = "[", control = "?" }

    -- Wrap cursor
    function commands.A(t, args)
        t.cy = t.cy - math.max(args[1] or 0, 1); wrap_cursor(t)
    end

    function commands.B(t, args)
        t.cy = t.cy + math.max(args[1] or 0, 1); wrap_cursor(t)
    end

    function commands.C(t, args)
        t.cx = t.cx + math.max(args[1] or 0, 1); wrap_cursor(t)
    end

    function commands.D(t, args)
        t.cx = t.cx - math.max(args[1] or 0, 1); wrap_cursor(t)
    end

    function commands.g(t, args)
        if #args < 1 then return end
        local cmd = table.remove(args, 1)
        if cmd == 0 then
            if #args < 4 then return end
            args[1] = math.max(1, math.min(args[1], t.w))
            args[2] = math.max(1, math.min(args[2], t.h))
            t.gpu.fill(args[1], args[2], args[3], args[4], " ")
        elseif cmd == 1 then
            if #args < 6 then return end
            t.cursorSaved = nil -- fix relocate
            t.gpu.copy(args[1], args[2], args[3], args[4], args[5], args[6])
        end
    end

    function commands.G(t, args)
        t.cx = math.max(1, math.min(t.w, args[1] or 1))
    end

    function commands.H(t, args)
        local y, x = args[1] or 1, args[2] or 1
        t.cx = math.max(1, math.min(t.w, x))
        t.cy = math.max(1, math.min(t.h, y))
        wrap_cursor(t)
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
                -- mode == 5 (256-color) skipped
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

    -- ?c
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

    -- ?s enable/disable signal
    function control.s(t, args)
        args[1] = args[1] or 0
        for i = 1, #args do
            local n = args[i]
            if n == 0 then
                t.disabled = {}
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

    -- Shoves concat into this but otherwise is same

    -- What was under the cursor?
    self.cursorSaved = nil -- {x, y, char, fg, bg, fgp, bgp}

    -- Restores contents
    local function eraseCursor(t)
        local saved = t.cursorSaved
        if not saved then return end

        t.cursorSaved = nil

        t.gpu.setForeground(saved.fg, saved.fgp)
        t.gpu.setBackground(saved.bg, saved.bgp)
        t.gpu.set(saved.x, saved.y, saved.char)

        t.gpu.setForeground(t.fg, t.fgp)
        t.gpu.setBackground(t.bg, t.bgp)
    end
    self.eraseCursor = eraseCursor

    -- Draw the cursor
    local function drawCursor(t)
        local cur = t.cursor
        if not cur.enabled or not cur.visible then return end

        local shapeFn = cursorShapes[cur.shape] or cursorShapes.invert
        local glyph = shapeFn()

        local c, f, b, pf, pb = t.gpu.get(cur.x, cur.y)

        -- pallete index? tf?
        local savedFg = pf ~= nil and pf or f
        local savedBg = pb ~= nil and pb or b
        local savedFgp = pf ~= nil
        local savedBgp = pb ~= nil

        t.cursorSaved = {
            x = cur.x,
            y = cur.y,
            char = c,
            fg = savedFg,
            bg = savedBg,
            fgp = savedFgp,
            bgp = savedBgp
        }

        if glyph then
            t.gpu.setForeground(t.fg, t.fgp)
            t.gpu.setBackground(t.bg, t.bgp)
            t.gpu.set(cur.x, cur.y, glyph)
        else
            -- Invert
            t.gpu.setForeground(savedBg, savedBgp)
            t.gpu.setBackground(savedFg, savedFgp)
            t.gpu.set(cur.x, cur.y, c)
        end

        -- Restore
        t.gpu.setForeground(t.fg, t.fgp)
        t.gpu.setBackground(t.bg, t.bgp)
    end
    self.drawCursor = drawCursor

    function self:tickBlink()
        if not self.cursor.blink then return end
        self.cursor.blinkOn = not self.cursor.blinkOn
        if self.attributes.cursor then eraseCursor(self) end
        self.cursor.visible = self.cursor.blinkOn
        if self.attributes.cursor and self.cursor.visible then drawCursor(self) end
    end

    function self:setCursorBlink(enabled)
        self.cursor.blink = enabled ~= false
        if not self.cursor.blink then
            self.cursor.blinkOn = true
            if self.attributes.cursor then eraseCursor(self) end
            self.cursor.visible = true
            if self.attributes.cursor then drawCursor(self) end
        end
    end

    -- annoyinf
    local function breakPendingLine(t)
        if #t.rb > 0 and t.attributes.echo and not t.attributes.raw then
            t.cx, t.cy = 1, t.cy + 1
            wrap_cursor(t)
            syncCursor(t)
        end
    end
    self.breakPendingLine = breakPendingLine

    function self:write_str(str, isEcho)
        local gpu = self.gpu

        if not isEcho then
            breakPendingLine(self)
        end

        if self.attributes.cursor then
            eraseCursor(self)
        end

        str = str:gsub("\t", "  ")

        while #str > 0 do
            if self.in_esc then
                local esc_end = str:find("[a-zA-Z]")
                if not esc_end then
                    self.esc = self.esc .. str
                    str = ""
                else
                    self.in_esc = false
                    local finish
                    str, finish = pop(str, esc_end, true)
                    local esc = self.esc .. finish
                    self.esc = ""

                    local separator, raw_args, code = esc:match("\27([%[%?])([%-%d;]*)([a-zA-Z])")
                    raw_args = raw_args or "0"
                    local args = {}
                    for arg in raw_args:gmatch("([^;]+)") do
                        args[#args + 1] = tonumber(arg) or 0
                    end

                    if separator == separators.standard and commands[code] then
                        commands[code](self, args)
                    elseif separator == separators.control and control[code] then
                        control[code](self, args)
                    end
                    wrap_cursor(self)
                    syncCursor(self)
                end
            else
                if str:find("\a") then
                    computer.beep()
                end
                str = str:gsub("\a", "")
                str = str:gsub("\r", "\27[G")

                local next_esc = str:find("\27")
                if next_esc then
                    self.in_esc = true
                    self.esc = ""
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

        if not isEcho and #self.rb > 0 and self.attributes.echo and not self.attributes.raw then
            -- Redraw
            rawwrite(self, self.rb)
            wrap_cursor(self)
            syncCursor(self)
        end

        if self.attributes.cursor then
            drawCursor(self)
        end

        return true
    end

    -- nottylinebuffer supported but usually line buffers
    function self:write(...)
        local str = table.concat({ ... })
        if #str == 0 then return true end

        if self.attributes.line and not cfg("nottylinebuffer") then
            self.wb = self.wb .. str
            if self.wb:find("\n") then
                local ln = self.wb:match(".+\n") or self.wb:match(".-\n")
                self.wb = self.wb:sub(#ln + 1)
                return self:write_str(ln)
            elseif len(self.wb) > 2048 then
                local ln = self.wb
                self.wb = ""
                return self:write_str(ln)
            end
            return true
        else
            return self:write_str(str)
        end
    end

    function self:writeln(...)
        self:write(...)
        return self:write("\n")
    end

    function self:flush()
        if #self.wb > 0 then
            self:write_str(self.wb)
            self.wb = ""
        end
        return true
    end

    function self:clear()
        self.rb = ""
        self.wb = ""
        self.gpu.fill(1, 1, self.w, self.h, " ")
        self.cx, self.cy = 1, 1
        self.cursorSaved = nil
        syncCursor(self)
    end

    -- Cursor stuff

    -- Sets the glyph used to render the cursor
    function self:setCursorShape(shape)
        if self.attributes.cursor then eraseCursor(self) end
        self.cursor.shape = cursorShapes[shape] and shape or "invert"
        if self.attributes.cursor then drawCursor(self) end
    end

    function self:getCursorShape()
        return self.cursor.shape
    end

    function self:registerCursorShape(name, fn)
        cursorShapes[name] = fn
    end

    -- Set cursor (Not write pos)
    function self:setCursorPos(x, y)
        if self.attributes.cursor then eraseCursor(self) end
        self.cursor.follow = false
        self.cursor.x, self.cursor.y = x, y
        if self.attributes.cursor then drawCursor(self) end
    end

    -- Same
    function self:setCursorRowCol(row, col, toScreen)
        self.cursor.row, self.cursor.col = row, col
        if toScreen then
            local x, y = toScreen(row, col)
            self:setCursorPos(x, y)
        end
    end

    -- Sync
    function self:setCursorFollow(enabled)
        self.cursor.follow = enabled ~= false
        if self.cursor.follow then
            syncCursor(self)
        end
    end

    function self:setCursorVisible(visible)
        if self.attributes.cursor then eraseCursor(self) end
        self.cursor.visible = visible ~= false
        if self.attributes.cursor and self.cursor.visible then drawCursor(self) end
    end

    function self:getCursorVisible()
        return self.cursor.visible
    end

    -- I think the ansi code still works
    function self:setCursor(enabled)
        enabled = enabled ~= false
        if self.attributes.cursor and not enabled then eraseCursor(self) end
        self.attributes.cursor = enabled
        self.cursor.enabled = enabled
        if enabled then drawCursor(self) end
    end

    function self:getCursor()
        return self.attributes.cursor
    end

    -- Calling this just registers with a uid instead

    function self:attach(uid)
        self.attachedUids[uid] = true
    end

    function self:detach(uid)
        self.attachedUids[uid] = nil
    end

    local aliases = {
        [200] = "\27[A", [208] = "\27[B", [205] = "\27[C", [203] = "\27[D",
    }

    -- Key handling is goofy with this event library. May change
    function self:onKeyDown(char, code)
        if char == 0 and code == 0 then return end
        if self.attributes.xoff then return end            

        local ch = char
        local outChar = aliases[code] or
            (ch > 255 and unicode.char or string.char)(ch)
        local tw = outChar
        local sigName = nil -- set below if this keypress should notify self.onSignal

        if ch == 0 and not aliases[code] then
            return
        end

        if len(outChar) == 1 and ch == 0 then
            outChar, tw = "", ""
        elseif outChar:match("\27%[[ABCD]") then
            tw = string.format("^[%s", outChar:sub(-1))
        elseif #outChar == 1 and ch < 32 then
            local tch = string.char(
                (ch == 0 and 32) or
                (ch < 27 and ch + 96) or
                (ch == 27 and 91) or
                (ch == 28 and 92) or
                (ch == 29 and 93) or
                (ch == 30 and 126) or
                (ch == 31 and 63) or ch
            ):upper()

            local act = sigacts[tch]
            if act and not self.disabled[tch] and not self.attributes.raw then
                outChar = ""

                if tch == "D" then
                    -- EOF on empty
                    tw = ""
                    if #self.rb == 0 then
                        outChar = "\4"
                    end
                else
                    -- Print the guy
                    self.rb = ""
                    tw = "^" .. tch .. "\n"
                    sigName = act
                end
            else
                tw = "^" .. tch
            end
        end

        if not self.attributes.raw then
            if ch == 13 then
                outChar, tw = "\n", "\n"
            elseif ch == 8 then
                if #self.rb > 0 then
                    tw = "\27[D \27[D"
                    self.rb = usub(self.rb, 1, len(self.rb) - 1)
                else
                    tw = ""
                end
                outChar = ""
            end
        end

        if self.attributes.echo and not self.attributes.xoff then
            self:write_str(tw or "", true)
        end

        if not self.attributes.xoff then
            self.rb = self.rb .. outChar

            if outChar == "\n" then
                local line = self.rb
                self.rb = ""
                self.writer:write(line)
            elseif outChar == "\4" then
                self.rb = ""
                self.writer:pulseEof() -- ^D: one-shot EOF, not a dead pipe
            end
        end

        -- Fix eof 
        if sigName and self.onSignal then
            self:onSignal(sigName)
        end
    end

    function self:clipboard(text)
        for c in text:gmatch(".") do
            self:onKeyDown(c:byte(), 0)
        end
    end

    -- Want to read from tty? Weird but sure

    function self:read(n)
        n = n or math.huge
        self:flush()

        while (not self.rb:find("\n")) and len(self.rb) < n and not self.rb:find("\4") do
            coroutine.yield()
        end

        if self.rb:find("\4") then
            self.rb = ""
            return nil
        end

        local take = math.min(n, len(self.rb))
        local data = usub(self.rb, 1, take)
        self.rb = usub(self.rb, take + 1)
        return data
    end

    function self:readLine()
        self:flush()
        while not self.rb:find("\n") and not self.rb:find("\4") do
            coroutine.yield()
        end
        if self.rb:find("\4") then
            self.rb = ""
            return nil
        end
        local nl = self.rb:find("\n")
        local line = self.rb:sub(1, nl - 1)
        self.rb = self.rb:sub(nl + 1)
        return line
    end

    -- A better event library

    self.keyHandlerId = event.register(nil, function(sig, _addr, char, code)
        if sig == "key_down" then
            self:onKeyDown(char, code)
        elseif sig == "clipboard" then
            self:clipboard(code) -- clipboard signal's 3rd value is the pasted text
        end
    end, math.huge, math.huge)

    self.blinkTimerId = event.timer(0.5, function() self:tickBlink() end, math.huge)

    function self:close()
        self:flush()
        event.cancel(self.keyHandlerId)
        event.cancel(self.blinkTimerId)
        self.writer:close()
        return true
    end

    return self
end

return tty