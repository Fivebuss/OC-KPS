-- /lib/termio.lua
-- Termio is incredibly cursed, be warned

local termio = {}

local providers = {}

function termio.register(name, getRunner)
	providers[name] = getRunner
end

function termio.deregister(name)
	providers[name] = nil
end

local function getgetRunner(kind)
	local getRunner = providers[kind]
	if getRunner then return getRunner end

	local ok, mod = pcall(require, "termio.providers." .. kind)
	if ok then
		local f = (type(mod) == "table" and mod.open) or mod
		if type(f) == "function" then
			providers[kind] = f
			return f
		end
	end
	return nil
end

-- opens one with the various types
function termio.open(opts)
	opts = opts or {}

	local kind = opts.kind
	if not kind then
		if opts.tty then
			kind = "tty"
		elseif opts.reader or opts.writer or opts.stream then
			kind = "stream"
		else
			kind = "null"
		end
	end

	local getRunner = getgetRunner(kind)
	if not getRunner then
		return nil, "termio: no provider for kind '" .. tostring(kind) .. "'"
	end

	return getRunner(opts)
end

return termio
