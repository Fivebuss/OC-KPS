local unicode = require("unicode")
local event = require("sys.kernel.modules.event")
local io = require("sys.kernel.modules.io")

local tty = {}

function tty.new(gpu)
    local self = {
        gpu = gpu,
        x = 1,
        y = 1,
        lineBuf = {},
    }

    self.reader, self.writer = io.newPipeEndpoints(polaris.scheduler)

    function self:clear()
        local w, h = self.gpu.getResolution()
        self.gpu.fill(1, 1, w, h, " ")
        self.x = 1
        self.y = 1
    end

    function self:newline()
        local w, h = self.gpu.getResolution()
        self.x = 1
        self.y = self.y + 1
        if self.y > h then
            self.gpu.copy(1, 2, w, h - 1, 0, -1)
            self.gpu.fill(1, h, w, 1, " ")
            self.y = h
        end
    end

    -- Writes text, splitting on "\n" without ever injecting an extra
    -- trailing newline (that was the earlier bug: writing a single
    -- character like "a" always advanced to a new line).
    function self:write(...)
        local text = table.concat({ ... })
        if #text == 0 then
            return true
        end

        local w = self.gpu.getResolution()

        local parts = {}
        local last = 1
        for i = 1, #text do
            if text:sub(i, i) == "\n" then
                table.insert(parts, text:sub(last, i - 1))
                last = i + 1
            end
        end
        table.insert(parts, text:sub(last))
        -- parts[1..#parts-1] are lines that were followed by "\n"
        -- parts[#parts] had no trailing newline (may be "")

        for i, line in ipairs(parts) do
            while #line > 0 do
                local avail = w - self.x + 1
                local chunk = line:sub(1, avail)
                self.gpu.set(self.x, self.y, chunk)
                self.x = self.x + #chunk
                line = line:sub(#chunk + 1)

                if self.x > w then
                    self:newline()
                end
            end

            if i < #parts then
                self:newline()
            end
        end

        return true
    end

    function self:backspace()
        if #self.lineBuf == 0 then
            return
        end

        table.remove(self.lineBuf)

        if self.x > 1 then
            self.x = self.x - 1
            self.gpu.set(self.x, self.y, " ")
        else
            local w = self.gpu.getResolution()
            self.y = math.max(1, self.y - 1)
            self.x = w
            self.gpu.set(self.x, self.y, " ")
        end
    end

    function self:onKeyDown(char, code)
        if code == 28 then -- Enter
            local text = table.concat(self.lineBuf)
            self.lineBuf = {}
            self:write("\n")
            self.writer:write(text .. "\n")
        elseif code == 14 then -- Backspace
            self:backspace()
        elseif char and char ~= 0 then
            local c = unicode.char(char)
            table.insert(self.lineBuf, c)
            self:write(c)
        end
    end

    self.keyHandlerId = event.addHandler(function(sig, _addr, char, code)
        if sig == "key_down" then
            self:onKeyDown(char, code)
        end
    end)

    function self:flush()
        return true
    end

    function self:close()
        event.removeHandler(self.keyHandlerId)
        self.writer:close()
        return true
    end

    return self
end

return tty
