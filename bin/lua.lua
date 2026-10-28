-- /bin/lua.lua
-- I just snatched openOS's kinda?

local serialization = require("serialization")
local filesystem = require("filesystem")
local unicode = require("unicode")

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

-- Readline is alot better now
local termio = require("termio")
local readline = require("ksh.readline")

local session
if ctty then
    session = termio.open({ kind = "tty", tty = ctty })
elseif io and io.stdin and io.stdout then
    session = termio.open({ kind = "stream", reader = io.stdin, writer = io.stdout })
else
    session = termio.open({ kind = "null" })
end

local lineEditor = readline.new(session, { prompt = "\27[32mlua> \27[37m" })

local function repl()
    io.write("\27[37m" .. _VERSION .. " Copyright (C) 1994-2022 Lua.org, PUC-Rio\n")
    io.write("\27[93mEnter a statement and hit enter to evaluate it.\n")
    io.write("Prefix an expression with '=' to show its value.\n")
    io.write("Press Ctrl+D to exit the interpreter.\n\27[37m")

    -- Share the environment for the repl
    local replEnv = setmetatable({}, { __index = _ENV })

    local function stripLocal(cmd)
        local names, rest = cmd:match("^%s*local%s+([%a_][%w_%s,]-)%s*=(.+)$")
        if names then
            return names .. " =" .. rest
        end
        return cmd
    end

    while true do
        local command = lineEditor:read()

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
                    replEnv
                )
            else
                -- maybe skip =
                local stripped = stripLocal(command)
                code, reason = load(
                    "return " .. stripped,
                    "=stdin",
                    "t",
                    replEnv
                )

                if not code then
                    code, reason = load(
                        stripped,
                        "=stdin",
                        "t",
                        replEnv
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
local file = filesystem.open(first, "r")
if file then
    file:close()
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
