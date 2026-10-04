-- /bin/lua.lua
-- I just snatched openOS's kinda? 

local serialization = require("serialization")
local filesystem = require("filesystem")

local function traceback(err)
    if debug and debug.traceback then
        return debug.traceback(tostring(err))
    end

    return tostring(err)
end

local function writeValue(value)
    local ok, result = pcall(serialization.serialize, value, true)

    if ok then
        io.writeln(result)
    else
        io.writeln(tostring(value))
    end
end

local function writeResults(result)
    for i = 2, result.n do
        writeValue(result[i])
    end
end

local function runChunk(chunk, ...)
    return table.pack(xpcall(function(...)
        return chunk(...)
    end, traceback, ...))
end

local function runFile(filename, fileArgs)
    local handle, reason = filesystem.open(filename, "r")

    if not handle then
        io.writelnError(
            "lua: could not open " ..
            tostring(filename) ..
            ": " ..
            tostring(reason)
        )
        return false
    end

    local chunks = {}
    while true do
        local chunk = handle:read(math.huge)
        if not chunk then break end
        chunks[#chunks + 1] = chunk
    end
    handle:close()
    local buffer = table.concat(chunks)

    if buffer == "" and #chunks == 0 then
        io.writelnError("lua: could not read " .. tostring(filename))
        return false
    end

    -- Remove a shebang if present.
    buffer = buffer:gsub("^#![^\n]*", "")

    local chunk, reason = load(
        buffer,
        "=" .. filename,
        "t",
        _ENV
    )

    if not chunk then
        io.writelnError(tostring(reason))
        return false
    end

    local result = runChunk(chunk, table.unpack(fileArgs))

    if not result[1] then
        io.writelnError(tostring(result[2]))
        return false
    end

    return true
end

local function repl()
    io.writeln(
        (_VERSION or "Lua") ..
        " " ..
        (_COPYRIGHT or "")
    )

    io.writeln("Enter a statement and hit enter to evaluate it.")
    io.writeln("Prefix an expression with '=' to show its value.")
    io.writeln("Press Ctrl+D to exit the interpreter.")

    while true do
        io.write("\27[32mlua> \27[37m")
        io.flush()

        local command = io.read("l")

        if not command then
            io.writeln()
            return
        end

        -- Ignore empty input.
        if command ~= "" then
            local code
            local reason

            if command:sub(1, 1) == "=" then
                code, reason = load(
                    "return " .. command:sub(2),
                    "=stdin",
                    "t",
                    _ENV
                )
            else
                -- maybe skip = 
                code, reason = load(
                    "return " .. command,
                    "=stdin",
                    "t",
                    _ENV
                )

                if not code then
                    code, reason = load(
                        command,
                        "=stdin",
                        "t",
                        _ENV
                    )
                end
            end

            if not code then
                io.writelnError(tostring(reason))
            else
                local result = runChunk(code)

                if not result[1] then
                    io.writelnError(tostring(result[2]))
                else
                    writeResults(result)
                end
            end
        end

        coroutine.yield()
    end
end

local args = args or {}

if #args == 0 then
    repl()
    return
end

local first = console.stripQuotes(args[1])
local extraArgs = {}

for i = 2, #args do
    extraArgs[#extraArgs + 1] = console.stripQuotes(args[i])
end

-- If it opens as a file, run it as a file; otherwise treat as a string to eval
local probe = filesystem.open(first, "r")
if probe then
    probe:close()
    runFile(first, extraArgs)
else
    local chunk, reason = load(first, "=arg", "t", _ENV)
    if not chunk then
        io.writelnError(tostring(reason))
        return
    end
    local result = runChunk(chunk, table.unpack(extraArgs))
    if not result[1] then
        io.writelnError(tostring(result[2]))
    else
        writeResults(result)
    end
end