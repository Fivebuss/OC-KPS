-- /lib/termio/providers/null.lua
-- Go away

local function open(opts)
	opts = opts or {}

	local session = {
		attributes = {},
	}

	function session:write(str) end
	function session:write_str(str) end
	function session:writeln(str) end
	function session:flush() end
	function session:readLine() return nil end
	function session:read(n) return nil end
	function session:clearInput() end
	function session:getSize() return 80, 24 end

	return session
end

return open
