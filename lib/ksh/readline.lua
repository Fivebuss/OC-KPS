-- /lib/ksh/readline.lua
-- Just shoved my readline code into a module.
-- It does the usual stuff, line editing, history, usual keybinds
-- May be lacking

local unicode = require("unicode")
local process = require("process")

local readline = {}
readline.__index = readline

local function defaultMaxLen()
	local v = polaris and polaris.config and polaris.config["ksh_history_length"]
	if type(v) == "number" and v > 0 then
		return math.floor(v)
	end
	return 16
end

local function utf8_chars(s)
	local i = 0
	return function()
		i = i + 1
		local c = unicode.sub(s, i, i)
		return c ~= "" and c or nil
	end
end

local function displayWidth(s)
	if unicode.wlen then
		return unicode.wlen(s)
	end
	if unicode.len then
		return unicode.len(s)
	end
	return #s
end

local function cursorLeft(session, columns)
	if columns > 0 then
		session:write_str("\27[" .. columns .. "D")
	end
end

local function cursorRight(session, columns)
	if columns > 0 then
		session:write_str("\27[" .. columns .. "C")
	end
end

function readline.new(session, opts)
	opts = opts or {}
	local self = setmetatable({}, readline)

	self.session = session
	self.prompt = opts.prompt or "> "
	self.history = opts.history or { entries = {}, maxLen = defaultMaxLen() }

	return self
end

function readline:promptString()
	if type(self.prompt) == "function" then
		return tostring(self.prompt() or "")
	end
	return tostring(self.prompt)
end

-- I wont do persistent history. No point
function readline:push(line)
	if line == nil or line == "" then return end
	local h = self.history.entries
	if h[#h] == line then return end
	h[#h + 1] = line
	local max = self.history.maxLen or 16
	while #h > max do
		table.remove(h, 1)
	end
end

function readline:read(skipPromptDraw)
	local session = self.session

	if not session.setDiscipline then
		if not skipPromptDraw and session.write_str then
			session:write_str(self:promptString())
		end
		if session.flush then session:flush() end
		if session.clearInput then session:clearInput() end
		if session.readLine then
			return session:readLine()
		end
		return nil
	end

	local prompt = self:promptString()

	-- Fix multi-line
	local width, _ = session:getSize()
	if type(width) ~= "number" or width <= 0 then
		width = 80
	end
	local promptW = displayWidth(prompt)

	local curRelRow = 1
	local curRelCol = 1

	local function relPos(contentW)
		return math.floor(contentW / width) + 1, (contentW % width) + 1
	end

	local buf = {}
	local pos = 0
	local hIdx = nil
	local liveBuf = {}

	local resultLine = nil
	local done = false

	if not skipPromptDraw then
		session:write_str(prompt)
		if session.flush then session:flush() end
	end
	curRelRow, curRelCol = relPos(promptW)

	local function redrawLine()
		local line = table.concat(buf)
		local prefixW = displayWidth(table.concat(buf, "", 1, pos))
		local suffixW = displayWidth(table.concat(buf, "", pos + 1))
		local contentW = promptW + prefixW
		local targetRow, targetCol = relPos(contentW)

		local out = { "\27[G" }
		if curRelRow > 1 then
			out[#out + 1] = "\27[" .. (curRelRow - 1) .. "A"
		end
		out[#out + 1] = "\27[J"
		out[#out + 1] = prompt
		out[#out + 1] = line
		if suffixW > 0 then
			out[#out + 1] = "\27[" .. suffixW .. "D"
		end
		session:write_str(table.concat(out))
		curRelRow, curRelCol = targetRow, targetCol
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

	local function historyUp()
		local h = self.history.entries
		if #h == 0 then return end

		if hIdx == nil then
			liveBuf = { table.unpack(buf) }
			hIdx = #h
		else
			hIdx = math.max(1, hIdx - 1)
		end

		replaceBuffer(h[hIdx])
		redrawLine()
	end

	local function historyDown()
		local h = self.history.entries
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
	end

	-- nil/eof mess
	local function finish(line, newline)
		resultLine = line
		done = true
		if newline ~= false then
			session:write_str("\n")
		end
	end

	local disc = {}

	function disc.onKeyDown(_, _, char, code)
		if done then return true end
		if session.attributes.xoff then return true end

		-- Backspace
		if char == 8 then
			if pos > 0 then
				table.remove(buf, pos)
				pos = pos - 1
				resetHistoryNavigation()
				if pos == #buf then
					if session.attributes.echo then
						session:write_str("\27[D \27[D")
					end
					curRelRow, curRelCol = relPos(promptW + displayWidth(table.concat(buf, "", 1, pos)))
				else
					redrawLine()
				end
			end
			return true
		end

		-- Delete
		if char == 127 then
			if pos < #buf then
				table.remove(buf, pos + 1)
				resetHistoryNavigation()
				redrawLine()
			end
			return true
		end

		-- Navigating around
		if char == 0 then
			if code == 200 then -- up arrow
				historyUp()
			elseif code == 208 then -- down arrow
				historyDown()
			elseif code == 203 then -- left arrow
				if pos > 0 then
					local ch = buf[pos]
					pos = pos - 1
					cursorLeft(session, displayWidth(ch))
					curRelRow, curRelCol = relPos(promptW + displayWidth(table.concat(buf, "", 1, pos)))
				end
			elseif code == 205 then -- right arrow
				if pos < #buf then
					local ch = buf[pos + 1]
					pos = pos + 1
					cursorRight(session, displayWidth(ch))
					curRelRow, curRelCol = relPos(promptW + displayWidth(table.concat(buf, "", 1, pos)))
				end
			elseif code == 211 then -- delete
				if pos < #buf then
					table.remove(buf, pos + 1)
					resetHistoryNavigation()
					redrawLine()
				end
			elseif code == 199 then -- home
				pos = 0
				redrawLine()
			elseif code == 207 then -- end
				pos = #buf
				redrawLine()
			end
			return true
		end

		-- Enter
		if char == 13 then
			finish(table.concat(buf))
			return true
		end

		-- Ctrl A, home
		if char == 1 then
			pos = 0
			redrawLine()
			return true
		end

		-- Ctrl E, end
		if char == 5 then
			pos = #buf
			redrawLine()
			return true
		end

		-- Ctrl L, finally it was bugging me
		if char == 12 then
			session.tty:clear()
			session:write_str(prompt)
			curRelRow, curRelCol = relPos(promptW)
			redrawLine()
			return true
		end

		-- Ctrl D
		if char == 4 then
			if #buf == 0 then
				finish(nil)
			else
				table.remove(buf, pos + 1)
				resetHistoryNavigation()
				redrawLine()
			end
			return true
		end

		-- Who is this? Send it
		if char < 32 and char ~= 9 then
			finish("", false)
			return false
		end

		-- Hey look invalid characters cant happen (in theory)
		if char < 0 or char > 0x10FFFF or (char >= 0xD800 and char <= 0xDFFF) then
			return true
		end

		local ch = (char > 255 and unicode.char or string.char)(char)
		table.insert(buf, pos + 1, ch)
		pos = pos + 1
		resetHistoryNavigation()

		if pos == #buf then
			if session.attributes.echo then
				session:write_str(ch)
			end
			curRelRow, curRelCol = relPos(promptW + displayWidth(table.concat(buf, "", 1, pos)))
		else
			redrawLine()
		end
		return true
	end

	function disc.onClipboard(_, _, text)
		if done then return true end

		-- OpenComputers clipboard handling is pure ass
		-- So no multi-line paste for you (WHY DOES IT ARRIVE AS SEPERATE EVENTS)
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

		local lineEnd = nil
		for i, c in ipairs(buf) do
			if c == "\n" then
				lineEnd = i
				break
			end
		end

		if lineEnd then
			finish(table.concat(buf, "", 1, lineEnd - 1))
			return true
		end

		redrawLine()
		return true
	end

	-- Fix flickering
	local prevDisc = nil
	if session.setDiscipline then
		prevDisc = session.tty.discipline
	end

	session:setDiscipline(disc)

	while not done do -- this is cursed
		process.yield()
	end

	session:removeDiscipline()
	if prevDisc then
		session:setDiscipline(prevDisc)
	end

	if resultLine == nil then return nil end
	self:push(resultLine)
	return resultLine
end

return readline
