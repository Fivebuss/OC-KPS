-- /lib/termio/providers/stream.lua
-- May not be very useful!

local function open(opts)
	opts = opts or {}

	local stream = opts.stream
	local reader = opts.reader or stream
	local writer = opts.writer or stream

	local session = {}

	session.attributes = {}
	session.stream = stream

	function session:write(str)
		if not writer then return end
		return writer:write(str)
	end

	function session:write_str(str)
		return session:write(str)
	end

	function session:writeln(str)
		session:write(str)
		session:write("\n")
	end

	function session:flush()
		if writer and writer.flush then
			return writer:flush()
		end
	end

	function session:readLine()
		if not reader then return nil end
		return reader:readLine()
	end

	function session:read(n)
		if not reader then return nil end
		return reader:read(n)
	end

	function session:clearInput() end

	function session:getSize()
		return 80, 24
	end

	return session
end

return open
