-- /sys/kernel/modules/tty.lua
--
-- Ported from cynosure. Because it is the best tty library I have used

local unicode = require("unicode")
local event = require("event")
local computer = require("computer")
local io = require("io")

-- Process does it's job
local process = polaris.process

local term = dofile("/sys/drivers/term/init.lua")

local tty = {}

-- Uses my own scheduler

-- Internal tty characters
local sigacts = {
    D = true,        -- ^D eof
    C = "INT",       -- ^C int
    Z = "TSTP",      -- ^Z
    ["\\"] = "KILL", -- ^\ quit
}

-- Uses polaris.config instead

local function cfg(key)
    return polaris and polaris.config and polaris.config[key]
end

local len = unicode.len
local usub = unicode.sub
local mmin = math.min
local sfind, ssub = string.find, string.sub
local tconcat = table.concat

function tty.new(gpu, keyboard_addrs)
    local emu
    local self = setmetatable({}, {
        __index = function(_, key)
            local value = emu[key]
            if type(value) == "function" then
                return function(_, ...) return value(emu, ...) end
            end
            return value
        end,
    })

    self.attributes = { echo = true, line = true, raw = false, cursor = true, xoff = false }
    self.disabled = {}
    self.attachedUids = {}
    self.onSignal = nil
    self.keyboard_addrs = keyboard_addrs

    self.rb = ""
    self.wb = ""
    self.lastInput = 0

    self.discipline = nil

    self.term = term.new(gpu, self)
    emu = self.term

    -- Sure helps to have this i/o library
    self.reader, self.writer = io.newPipeEndpoints(process)

    local aliases = {
        [200] = "\27[A", [208] = "\27[B", [205] = "\27[C", [203] = "\27[D", [211] = "\27[3~",
    }

    -- Key handling is goofy with this event library. May change
    function self:onKeyDown(char, code)
        if self.suspended then return end
        if char == 0 and code == 0 then return end
        if self.attributes.xoff then return end
        self.lastInput = computer.uptime()

        local disc = self.discipline
        if disc and disc.onKeyDown and disc:onKeyDown(self, char, code) then
            return
        end

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
        elseif aliases[code] then
            tw = "^[" .. ssub(outChar, -1)
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
                    -- eof makes me want to die
                    tw = ""
                    outChar = "\4"
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
            self:writeStr(tw or "", true)
        end

        if not self.attributes.xoff then
            if outChar == "\4" then
                -- send to reader
                if #self.rb > 0 then
                    self.writer:write(self.rb)
                    self.rb = ""
                end
                self.writer:sigEof() -- pipes problem
            else
                self.rb = self.rb .. outChar

                if outChar == "\n" then
                    local line = self.rb
                    self.rb = ""
                    self.writer:write(line)
                end
            end
        end

        -- Fix eof
        if sigName and self.onSignal then
            self:onSignal(sigName)
        end
    end

    function self:clipboard(text)
        if self.suspended or self.attributes.xoff then return end
        self.lastInput = computer.uptime()

        local disc = self.discipline
        if disc and disc.onClipboard and disc:onClipboard(self, text) then
            return
        end

        if not self.attributes.raw then
            text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
        end
        if self.attributes.echo and not self.attributes.xoff then
            self:writeStr(text, true)
        end
        if not self.attributes.xoff then
            self.rb = self.rb .. text
            local nl = sfind(self.rb, "\n", 1, true)
            if nl then
                local line = ssub(self.rb, 1, nl)
                self.rb = ssub(self.rb, nl + 1)
                self.writer:write(line)
            end
        end
    end

    -- Want to read from tty? Weird but sure

    function self:read(n)
        n = n or math.huge
        self:flush()

        while (not sfind(self.rb, "\n", 1, true)) and len(self.rb) < n and not sfind(self.rb, "\4", 1, true) do
            local sig = coroutine.yield()
            if sig == "INT" then
                process.exit(130)
            end
        end

        local eof_pos = sfind(self.rb, "\4", 1, true)
        if eof_pos then
            local data = usub(self.rb, 1, eof_pos - 1)
            self.rb = ""
            return #data > 0 and data or nil
        end

        local take = mmin(n, len(self.rb))
        local data = usub(self.rb, 1, take)
        self.rb = usub(self.rb, take + 1)
        return data
    end

    function self:readLine()
        self:flush()
        while not sfind(self.rb, "\n", 1, true) and not sfind(self.rb, "\4", 1, true) do
            local sig = coroutine.yield()
            if sig == "INT" then
                process.exit(130)
            end
        end
        if sfind(self.rb, "\4", 1, true) then
            self.rb = ""
            return nil
        end
        local nl = sfind(self.rb, "\n", 1, true)
        local line = ssub(self.rb, 1, nl - 1)
        self.rb = ssub(self.rb, nl + 1)
        return line
    end

    -- no ttylinebuffer supported but usually line buffers
    function self:write(...)
        local str = tconcat({ ... })
        if #str == 0 then return true end

        if self.attributes.line and not cfg("nottylinebuffer") then
            self.wb = self.wb .. str
            local nl = sfind(self.wb, "\n", 1, true)
            if nl then
                local ln = ssub(self.wb, 1, nl)
                self.wb = ssub(self.wb, nl + 1)
                return self:writeStr(ln)
            elseif #self.wb > 2048 then
                local ln = self.wb
                self.wb = ""
                return self:writeStr(ln)
            end
            return true
        else
            return self:writeStr(str)
        end
    end

    function self:writeln(...)
        self:write(...)
        return self:write("\n")
    end

    function self:flush()
        if #self.wb > 0 then
            self:writeStr(self.wb)
            self.wb = ""
        end
        return true
    end

    function self:writeStr(str, isEcho)
        if not isEcho and #self.rb > 0 and self.attributes.echo and not self.attributes.raw then
            emu:newLine()
        end
        return emu:writeStr(str, isEcho)
    end

    function self:clear()
        self.rb = ""
        self.wb = ""
        emu:clear()
    end

    function self:setResolution(w, h)
        return emu:setResolution(w, h)
    end

    -- Readline can now do stuff without stealing event handlers, imagine that
    function self:setDiscipline(disc)
        self.discipline = disc
    end

    function self:removeDiscipline()
        self.discipline = nil
    end

    -- This makes my life easier
    function self:suspendInput()
        self.suspended = true
    end

    function self:resumeInput()
        self.suspended = false
    end

    function self:attach(uid)
        self.attachedUids[uid] = true
    end

    function self:detach(uid)
        self.attachedUids[uid] = nil
    end

    -- A better event library

    self.keyHandlerId = event.register(nil, function(sig, kb_addr, char, code)
        if self.keyboard_addrs and not self.keyboard_addrs[kb_addr] then return end
        if sig == "key_down" then
            self:onKeyDown(char, code)
        elseif sig == "clipboard" then
            -- Clipboard event's 3rd return (char) is the text, not the 4th (code)
            self:clipboard(char)
        end
    end, math.huge, math.huge)

    self.blinkTimerId = event.timer(0.5, function() self:tickBlink() end, math.huge)

    function self:close()
        self:flush()
        self:removeDiscipline()
        event.cancel(self.keyHandlerId)
        event.cancel(self.blinkTimerId)
        self.writer:close()
        return true
    end

    return self
end

return tty
