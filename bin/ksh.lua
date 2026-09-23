-- /bin/ksh.lua
-- Okay more stuff ported

local process = polaris.process
local filesystem = require("filesystem")
local io = polaris.io

local path = "/bin:/sbin"

local function splitPath(p)
    local parts = {}
    for entry in p:gmatch("[^:]+") do
        table.insert(parts, entry)
    end
    return parts
end

local pathDirs = splitPath(path)

local function resolveCommand(name)
    for _, dir in ipairs(pathDirs) do
        local candidate = filesystem.concat(dir, name .. ".lua")
        if filesystem.exists(candidate) and not filesystem.isDirectory(candidate) then
            return candidate
        end
    end
    return nil
end

-- Errors exist yay
local function writeRed(stream, ...)
    stream:write("\27[31m")
    stream:write(...)
    return stream:write("\27[0m")
end

local tty = polaris.tty.new(polaris.gpu)
tty:setCursorShape("underline")

-- For later
tty.disabled.Z = true

polaris.config["tty.profile"] = 7

-- Pipeline stuff
local function ttyOutPassthrough()
    return {
        write = function(_, ...) return tty:write(...) end,
        -- newline handling
        flush = function(_) return tty:flush() end,
        close = function() end,
    }
end

local function ttyInPassthrough()
    return {
        read = function(_, ...) return tty.reader:read(...) end,
        readLine = function(_, ...) return tty.reader:readLine(...) end,
        close = function() end,
    }
end

local shellPid
local lastExitCode = 0
local fgBusy = false -- true while a foreground pipeline is actually running

-- Just for the shell
local locals = {}

-- PWD
local currPath = "/"

local function drawPrompt()
    tty:write("\r" .. currPath .. "> ")
    tty:flush()
end

-- Deal with signals
tty.onSignal = function(_, sig)
    process.signalGroup(process.GROUP.USERFG, sig)
    if not fgBusy then
        drawPrompt()
    end
end

local function resolvePath(base, target)
    if not target or target == "" then
        return base
    end
    if target:sub(1, 1) ~= "/" then
        target = filesystem.concat(base, target)
    end
    return filesystem.canonical(target)
end

local function stripQuotes(s)
    if #s >= 2 then
        local a, b = s:sub(1, 1), s:sub(-1)
        if (a == '"' and b == '"') or (a == "'" and b == "'") then
            return s:sub(2, -2)
        end
    end
    return s
end

-- Useful stuff in console. Will remove for later or expose to env
local console = {
    resolvePath = resolvePath,
    currPath = function() return currPath end,
    stripQuotes = stripQuotes,
}

-- Hmmm
local function lookupVar(name, getenv)
    local v = locals[name]
    if v ~= nil then return v end
    return getenv(name)
end

-- support for :-  :=  :+  :? 
local function applyOperator(name, op, arg, value)
    if value ~= nil and value ~= "" then
        if op == "+" then return arg end
        return value
    end

    if op == "-" then return arg end
    if op == "=" then
        locals[name] = arg
        return arg
    end
    if op == "?" then
        return nil, arg ~= "" and arg or (name .. ": parameter not set")
    end
    return "" -- :+ with unset value
end

-- Todo: make better
local function expandVars(str, getenv)
    local failMsg
    local out = str:gsub("%$%b{}", function(tok)
        local body = tok:sub(3, -2)
        local name, op, arg = body:match("^([%a_][%w_]*):([%-=+?])(.*)$")
        if name then
            local result, err = applyOperator(name, op, arg, lookupVar(name, getenv))
            if err then failMsg = failMsg or err end
            return result or ""
        end
        if body == "?" then return tostring(lastExitCode) end
        if body == "$" then return tostring(shellPid or 0) end
        return lookupVar(body, getenv) or ""
    end)
    out = out:gsub("%$%?", tostring(lastExitCode))
    out = out:gsub("%$%$", tostring(shellPid or 0))
    out = out:gsub("%$([%a_][%w_]*)", function(name)
        return lookupVar(name, getenv) or ""
    end)
    return out, failMsg
end

-- -- Tokenizer is miles shorter, thanks text library
local function splitAndChain(line)
    local groups = {}
    local current = {}
    local inD, inS = false, false
    local i, len = 1, #line

    while i <= len do
        local c = line:sub(i, i)
        if c == '"' and not inS then
            inD = not inD
            current[#current + 1] = c
        elseif c == "'" and not inD then
            inS = not inS
            current[#current + 1] = c
        elseif c == "&" and line:sub(i + 1, i + 1) == "&" and not inD and not inS then
            groups[#groups + 1] = table.concat(current)
            current = {}
            i = i + 1 -- skip the second &
        else
            current[#current + 1] = c
        end
        i = i + 1
    end
    groups[#groups + 1] = table.concat(current)
    return groups
end

-- Splits on | outside quote
local function splitPipes(line)
    local segments = {}
    local current = {}
    local inD, inS = false, false

    for i = 1, #line do
        local c = line:sub(i, i)
        if c == '"' and not inS then
            inD = not inD
            current[#current + 1] = c
        elseif c == "'" and not inD then
            inS = not inS
            current[#current + 1] = c
        elseif c == "|" and not inD and not inS then
            segments[#segments + 1] = table.concat(current)
            current = {}
        else
            current[#current + 1] = c
        end
    end
    segments[#segments + 1] = table.concat(current)
    return segments
end

-- Elseif elseif elseif
-- Yes tokenizing is still a better idea
local function tokenize(segment)
    local words = {}
    local current = {}
    local inD, inS = false, false
    local i, len = 1, #segment

    local function flush()
        if #current > 0 then
            words[#words + 1] = table.concat(current)
            current = {}
        end
    end

    while i <= len do
        local c = segment:sub(i, i)
        if c == '"' and not inS then
            inD = not inD
            current[#current + 1] = c
        elseif c == "'" and not inD then
            inS = not inS
            current[#current + 1] = c
        elseif c:match("%s") and not inD and not inS then
            flush()
        elseif c == "<" and not inD and not inS then
            flush()
            words[#words + 1] = "<"
        elseif c == ">" and not inD and not inS then
            flush()
            if segment:sub(i + 1, i + 1) == ">" then
                words[#words + 1] = ">>"
                i = i + 1
            else
                words[#words + 1] = ">"
            end
        else
            current[#current + 1] = c
        end
        i = i + 1
    end
    flush()
    return words
end

-- Grabs < > >> for now, expands stuff
local function parseSegment(segment, getenv)
    local words = tokenize(segment)
    if #words == 0 then
        return nil, "empty command"
    end

    local args = {}
    local redirects = { stdinFile = nil, stdoutFile = nil, appendOut = false }
    local i = 1
    local expandFail
    local function expand(w)
        local out, failMsg = expandVars(stripQuotes(w), getenv)
        expandFail = expandFail or failMsg
        return out
    end
    while i <= #words do
        local w = words[i]
        if w == "<" then
            if not words[i + 1] then return nil, "missing filename after <" end
            redirects.stdinFile = expand(words[i + 1])
            i = i + 2
        elseif w == ">" then
            if not words[i + 1] then return nil, "missing filename after >" end
            redirects.stdoutFile = expand(words[i + 1])
            redirects.appendOut = false
            i = i + 2
        elseif w == ">>" then
            if not words[i + 1] then return nil, "missing filename after >>" end
            redirects.stdoutFile = expand(words[i + 1])
            redirects.appendOut = true
            i = i + 2
        else
            args[#args + 1] = expand(w)
            i = i + 1
        end
    end

    if #args == 0 then
        return nil, "empty command"
    end

    if expandFail then
        return nil, expandFail, true
    end

    return { args = args, redirects = redirects }
end

local builtins = {}

-- args[1] is back to being normal
local function argv(segArgs)
    local out = {}
    for i = 2, #segArgs do
        out[i - 1] = segArgs[i]
    end
    return out
end

-- So we can support redirection
local function fdStream(fd)
    return setmetatable({}, {
        __index = function(_, key)
            return function(_, ...)
                local desc = process.stream(fd)
                return desc[key](desc, ...)
            end
        end,
    })
end

-- Pipe stuff
-- 'a' append mode is weird
local function openForOutput(full, append)
    return io.newFileStream(full, append and "a" or "w")
end

-- Decides fd0/1/2 or tty
local function makeStreams(inPipe, outPipe, redirects, fallbackStdin)
    local stdin, stdout

    if redirects.stdinFile then
        local full = resolvePath(currPath, redirects.stdinFile)
        if not filesystem.exists(full) then
            return nil, nil, nil, "no such file: " .. redirects.stdinFile
        end
        local stream, reason = io.newFileStream(full, "r")
        if not stream then return nil, nil, nil, tostring(reason) end
        stdin = stream
    else
        stdin = inPipe or fallbackStdin or io.newStream()
    end

    if redirects.stdoutFile then
        local full = resolvePath(currPath, redirects.stdoutFile)
        local stream, reason = openForOutput(full, redirects.appendOut)
        if not stream then return nil, nil, nil, tostring(reason) end
        stdout = stream
    else
        stdout = outPipe or ttyOutPassthrough()
    end

    return stdin, stdout, ttyOutPassthrough()
end

-- Runs pipeline
local function runPipeline(parsedSegments, tempAssigns)
    local segCount = #parsedSegments
    local pipes = {}
    for i = 1, segCount - 1 do
        pipes[i] = io.newPipe(polaris.scheduler, 8192)
    end

    local results = {}
    local remaining = segCount
    local waiterPid = process.self()
    local spawnedAny = false
    local pids = {}

    local function detachAll()
        if tty.attach then
            for _, pid in ipairs(pids) do
                tty:detach(pid)
            end
        end
    end

    local function segmentDone(segIdx, exitCode, inPipe, outPipe)
        if outPipe then outPipe:close() end
        if inPipe then inPipe:closeRead() end
        results[segIdx] = exitCode
        remaining = remaining - 1
        if remaining <= 0 then
            detachAll()
            process.send(waiterPid, true)
        end
    end

    local tempEnvValues
    if tempAssigns then
        tempEnvValues = {}
        for _, a in ipairs(tempAssigns) do
            tempEnvValues[a.name] = locals[a.name]
        end
    end

    for segIdx = 1, segCount do
        local seg = parsedSegments[segIdx]
        local inPipe = pipes[segIdx - 1]
        local outPipe = pipes[segIdx]
        local builtin = builtins[seg.args[1]]
        local resolved = not builtin and resolveCommand(seg.args[1])

        if not builtin and not resolved then
            writeRed(tty, "ksh: command not found: " .. tostring(seg.args[1]), "\n")
            segmentDone(segIdx, 127, inPipe, outPipe)
        else
            local stdin, stdout, stderr, err = makeStreams(
                inPipe, outPipe, seg.redirects,
                segIdx == 1 and ttyInPassthrough() or nil)

            if err then
                writeRed(tty, "ksh: " .. err, "\n")
                segmentDone(segIdx, 1, inPipe, outPipe)
            else
                spawnedAny = true
                local pid
                pid = process.spawn(function()
                    local env = polaris.env.current()
                    env.console = console
                    env.args = argv(seg.args)
                    env.setenv("PWD", currPath)
                    if segIdx == 1 and tempEnvValues then
                        for name, value in pairs(tempEnvValues) do
                            env.setenv(name, value)
                        end
                    end
                    -- Errors? Why
                    env.io = {
                        write = function(...) return process.write(...) end,
                        writeln = function(...)
                            process.write(...); return process.write("\n")
                        end,
                        writeError = function(...) return process.writeError(...) end,
                        writelnError = function(...)
                            process.writeError(...); return process.writeError("\n")
                        end,
                        read = function(...) return process.input():read(...) end,
                        readline = function(...) return process.input():readLine(...) end,
                        flush = function() return process.output():flush() end,

                        -- Hey look, actual stream objects
                        stdin = fdStream(0),
                        stdout = fdStream(1),
                        stderr = fdStream(2),
                    }

                    local ok, err = xpcall(function()
                        if builtin then
                            return builtin(argv(seg.args), process.input(), {
                                write = function(_, ...) return process.write(...) end,
                                close = function() end,
                            }, {
                                write = function(_, ...) return process.writeError(...) end,
                                close = function() end,
                            })
                        end

                        local src, reason = filesystem.open(resolved, "r")
                        if not src then error(reason or "cannot open", 0) end
                        local chunks = {}
                        while true do
                            local chunk = src:read(math.huge)
                            if not chunk then break end
                            chunks[#chunks + 1] = chunk
                        end
                        src:close()

                        local fn, loadErr = env.load(table.concat(chunks), "=" .. resolved, "bt")
                        if not fn then error(loadErr, 0) end
                        return fn(table.unpack(seg.args, 2))
                    end, debug.traceback)

                    if not ok then
                        process.error():write("\27[31m", tostring(err), "\n\27[0m")
                        process.exit(1)
                    end
                end, {
                    label = seg.args[1],
                    pgid = process.GROUP.USERFG,
                    ppid = shellPid,
                    onExit = function(success, exitCode)
                        local code = (type(exitCode) == "number") and exitCode or (success and 0 or 1)
                        segmentDone(segIdx, code, inPipe, outPipe)
                    end,
                })

                process.create(pid, stdin, stdout, stderr)
                pids[#pids + 1] = pid
                if tty.attach then
                    tty:attach(pid)
                end
            end
        end
    end

    if spawnedAny and remaining > 0 then
        fgBusy = true
        process.waitForInput()
        fgBusy = false
        -- Newline prompt redraw
        if tty.cx > 1 then
            tty:write("\n")
        end
    end

    lastExitCode = results[segCount] or lastExitCode
end

-- Shell builtins are sane

function builtins.exit()
    process.exit(0)
end

function builtins.clear()
    tty:clear()
end

function builtins.cd(args, _, _, _)
    local target = args[1] or "/"
    local full = resolvePath(currPath, target)
    if not filesystem.exists(full) then
        writeRed(tty, "cd: no such directory: " .. target, "\n")
        lastExitCode = 1
        return
    end
    if not filesystem.isDirectory(full) then
        writeRed(tty, "cd: not a directory: " .. target, "\n")
        lastExitCode = 1
        return
    end
    currPath = full
    lastExitCode = 0
end

-- Just -n for now
function builtins.echo(args, stdin, stdout, stderr)
    local noNewline = false
    local words = {}

    for i = 1, #args do
        if i == 1 and args[i] == "-n" then
            noNewline = true
        else
            words[#words + 1] = args[i]
        end
    end

    local line = table.concat(words, " ")

    if noNewline then
        stdout:write(line)
        stdout:flush()
    else
        stdout:write(line, "\n")
    end
    lastExitCode = 0
end

function builtins.pwd(args, stdin, stdout, stderr)
    stdout:write(currPath, "\n")
    lastExitCode = 0
end

-- hey local variable, congratulations on migrating
function builtins.export(args, stdin, stdout, stderr)
    local env = polaris.env.current()

    if #args == 0 then
        for k, v in pairs(env.getall()) do
            stdout:write(k .. "=" .. tostring(v), "\n")
        end
        lastExitCode = 0
        return
    end

    for _, arg in ipairs(args) do
        local name, value = arg:match("^([%a_][%w_]*)=(.*)$")
        if name then
            locals[name] = nil
            env.setenv(name, value)
        else
            env.setenv(arg, locals[arg] or env.getenv(arg))
            locals[arg] = nil
        end
    end
    lastExitCode = 0
end

-- goodbye variable
function builtins.unset(args, stdin, stdout, stderr)
    local env = polaris.env.current()
    for _, name in ipairs(args) do
        locals[name] = nil
        env.setenv(name, nil)
    end
    lastExitCode = 0
end

-- set hopefully works
function builtins.set(args, stdin, stdout, stderr)
    if #args == 0 then
        local env = polaris.env.current()
        local seen = {}
        for k, v in pairs(env.getall()) do
            stdout:write(k .. "=" .. tostring(v), "\n")
            seen[k] = true
        end
        for k, v in pairs(locals) do
            if not seen[k] then
                stdout:write(k .. "=" .. tostring(v), "\n")
            end
        end
        lastExitCode = 0
        return
    end

    for _, arg in ipairs(args) do
        local name, value = arg:match("^([%a_][%w_]*)=(.*)$")
        if name then
            locals[name] = value
        end
    end
    lastExitCode = 0
end

-- The input

-- Mmmm lists, returns them
local function splitAssignments(words)
    local assigns = {}
    local i = 1
    while words[i] do
        local name, value = stripQuotes(words[i]):match("^([%a_][%w_]*)=(.*)$")
        if not name then break end
        assigns[#assigns + 1] = { name = name, value = value }
        i = i + 1
    end
    local rest = {}
    for j = i, #words do
        rest[#rest + 1] = words[j]
    end
    return assigns, rest
end

-- Everything but &&
local function runCommandGroup(line, getenv)
    -- KEY=value
    local words = tokenize(line)
    local assigns, rest = splitAssignments(words)

    if #assigns > 0 and #rest == 0 then
        for _, a in ipairs(assigns) do
            locals[a.name] = expandVars(a.value, getenv)
        end
        lastExitCode = 0
        return
    end

    local saved
    local savedNames
    if #assigns > 0 then
        saved = {}
        savedNames = {}
        for _, a in ipairs(assigns) do
            saved[a.name] = locals[a.name]
            savedNames[#savedNames + 1] = a.name
            locals[a.name] = expandVars(a.value, getenv)
        end
        line = table.concat(rest, " ")
    end

    local function restoreLocals()
        if not savedNames then return end
        for _, name in ipairs(savedNames) do
            locals[name] = saved[name]
        end
    end

    local rawSegments = splitPipes(line)
    local parsed = {}

    for _, raw in ipairs(rawSegments) do
        local seg, err, isParamError = parseSegment(raw, getenv)
        if not seg then
            if isParamError then
                writeRed(tty, "ksh: " .. err, "\n")
                lastExitCode = 1
            else
                writeRed(tty, "ksh: syntax error: " .. err, "\n")
                lastExitCode = 2
            end
            restoreLocals()
            return
        end
        parsed[#parsed + 1] = seg
    end

    -- Shell process has builtins
    local first = parsed[1].args[1]

    if #parsed == 1 and builtins[first] then
        local seg = parsed[1]

        local stdin, stdout, stderr, err = makeStreams(
            nil,
            nil,
            seg.redirects,
            ttyInPassthrough()
        )

        if err then
            writeRed(tty, "ksh: " .. err, "\n")
            lastExitCode = 1
            restoreLocals()
            return
        end

        -- I likely dont need this anymore now that builtins go through write as usual
        local ok, builtinErr = xpcall(
            function()
                return builtins[first](
                    argv(seg.args),
                    stdin,
                    stdout,
                    stderr
                )
            end,
            debug.traceback
        )

        -- Cleanup time
        if stdin then
            stdin:close()
        end
        if stdout then
            stdout:close()
        end
        if stderr then
            stderr:close()
        end

        if not ok then
            writeRed(tty, tostring(builtinErr), "\n")
            lastExitCode = 1
        end

        restoreLocals()
        return
    end

    runPipeline(parsed, saved and assigns)
    restoreLocals()
end

local function executeLine(line, getenv)
    line = line:gsub("[\r\n]+$", "")
    if line:match("^%s*$") then return end

    local groups = splitAndChain(line)

    for _, group in ipairs(groups) do
        if group:match("^%s*$") then
            writeRed(tty, "ksh: syntax error near '&&'", "\n")
            lastExitCode = 2
            return
        end

        runCommandGroup(group, getenv)

        if lastExitCode ~= 0 then
            -- && skip
            return
        end
    end
end

-- Loop. I hate this.

local function shellLoop()
    tty:clear()
    tty:write("ksh loaded\n")

    local stdin = process.input()
    local env = polaris.env.current()
    env.setenv("PWD", currPath)

    while true do
        -- To fix cursor bug I do \r lol, as I am to busy to fix it normally
        drawPrompt()

        local line = stdin:readLine()

        if not line then
            tty:write("\n")
            return
        end

        env.setenv("PWD", currPath)
        executeLine(line, env.getenv)
    end
end

shellPid = process.spawn(shellLoop, {
    label = "ksh",
    pgid = process.GROUP.USER,
    onExit = function(success, reason)
        computer.beep(2000)
        computer.beep(2000)

        if tty.attach then
            tty:setCursor(false)
            tty:clear()
            tty:detach(shellPid)
            tty:close()
        end
        process.destroy(shellPid)
    end,
})

process.create(shellPid, tty.reader, tty, tty)

if tty.attach then
    tty:attach(shellPid)
end