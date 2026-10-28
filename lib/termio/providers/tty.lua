-- /lib/termio/providers/tty.lua
-- Just makes a tty around termio

local function open(opts)
	opts = opts or {}

	local tty = opts.tty
	if not tty then
		local gpu = opts.gpu or polaris.gpu
		tty = polaris.tty.new(gpu)
	end

	local session = {}

	session.tty = tty
	session.attributes = tty.attributes

	-- Output
	function session:write(...) return tty:write(...) end
	function session:writeln(...) return tty:writeln(...) end
	function session:write_str(str, ...) return tty:write_str(str, ...) end
	function session:flush() return tty:flush() end

	-- Input
	function session:readLine() return tty:readLine() end
	function session:read(n) return tty:read(n) end
	function session:clearInput() tty.rb = "" end

	function session:setDiscipline(disc) return tty:setDiscipline(disc) end
	function session:removeDiscipline() return tty:removeDiscipline() end

	function session:getSize() return tty.w, tty.h end
	function session:setCursorShape(shape) return tty:setCursorShape(shape) end
	function session:setCursorVisible(v) return tty:setCursorVisible(v) end

	return session
end

return open
