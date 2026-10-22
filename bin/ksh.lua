-- /bin/ksh.lua
-- Okay more stuff ported

local process = polaris.process
polaris.analytics.addEvent("ksh-" .. process.self().uid)
local filesystem = require("filesystem")
local io = polaris.io
local text = require("text")
local unicode = require("unicode")

-- Errors exist yay
local function writeRed(stream, ...)
    stream:write("\27[31m")
    stream:write(...)
    stream:write("\27[0m")
    if stream.flush then
        pcall(function() stream:flush() end)
    end
end

local tty = polaris.console.openTTY({
    gpu   = gpu,
    owner = process.self().pid,
})

tty:setCursorShape("underline")

-- For later
tty.disabled.Z = true

--polaris.config["tty.profile"] = 7

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
local shellUid

-- Ok fine. Il do it
local shellStates = {}
local shellState = {
    locals = {},      -- variables
    scriptArgs = nil, -- $0, $1, etc
    aliases = {},
    currPath = "/",
    lastExitCode = 0,
    fgBusy = false,    -- true while a foreground pipeline is actually going
    gid = process.GID.FG, -- No jobs yet.
    asyncJobs = {},    -- wait
}

local function st()
    return shellStates[process.activeThread()] or shellState
end

local function inSubshell()
    return shellStates[process.activeThread()] ~= nil
end

-- This is cursed, il pull a mshell
local captureSubshell, spawnSubshell, executeTokens, runScriptLines

local function drawPrompt()
    tty:write(st().currPath .. "> ")
    tty:flush()
end

-- Deal with signals
local signalPrompt = false
tty.onSignal = function(_, sig)
    if shellUid then
        process.signalGroup(shellUid, process.GID.FG, sig)
    end
    if not shellState.fgBusy then
        drawPrompt()
        signalPrompt = true
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

local function makeConsole(pwd)
    return {
        resolvePath = resolvePath,
        currPath = function() return pwd end,
        stripQuotes = stripQuotes,
    }
end

-- Okay text library time
local function tokenize(line)
    local tokens, err = text.tokenize(line)
    if not tokens then return nil, err end
    return tokens
end

-- # is comment, but not inside quotes or a ( subshell ), I hope atleast
local function stripComments(line)
    local stripped = {}
    local inD, inS = false, false
    local subDepth = 0
    for i = 1, #line do
        local c = line:sub(i, i)
        if c == '"' and not inS then
            inD = not inD
        elseif c == "'" and not inD then
            inS = not inS
        elseif c == "(" and not inD and not inS then
            subDepth = subDepth + 1
        elseif c == ")" and not inD and not inS and subDepth > 0 then
            subDepth = subDepth - 1
        elseif c == "#" and not inD and not inS and subDepth == 0 then
            break
        end
        stripped[#stripped + 1] = c
    end
    return table.concat(stripped)
end

-- aaaaaa quotes
local function tokenIsQuoted(s)
    return #s >= 2 and (
        (s:sub(1, 1) == "'" and s:sub(-1) == "'") or
        (s:sub(1, 1) == '"' and s:sub(-1) == '"') or
        (s:sub(1, 1) == "`" and s:sub(-1) == "`"))
end

-- Hmmm
local function lookupVar(name, getenv)
    if st().scriptArgs then
        if name == "0" then return st().scriptArgs[1] or "" end
        local num = tonumber(name)
        if num then return st().scriptArgs[num + 1] or "" end
        if name == "#" then return tostring(math.max(0, #st().scriptArgs - 1)) end
        if name == "@" or name == "*" then
            local t = {}
            for i = 2, #st().scriptArgs do t[#t + 1] = st().scriptArgs[i] end
            return table.concat(t, " ")
        end
    end
    local v = st().locals[name]
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
        st().locals[name] = arg
        return arg
    end
    if op == "?" then
        return nil, arg ~= "" and arg or (name .. ": parameter not set")
    end
    return "" -- :+ with unset value
end

-- text match too big for this lol
local function matchParen(s, from)
    local depth = 0
    local i = from
    local n = #s
    while i <= n do
        local c = s:sub(i, i)
        if c == "'" or c == '"' then
            i = i + 1
            while i <= n and s:sub(i, i) ~= c do
                i = i + 1
            end
            if i > n then return nil end
        elseif c == "(" then
            depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then return i end
        end
        i = i + 1
    end
    return nil
end

-- Substitution in a subshell. Yes I strip newline, bite me
local function runCapture(body, getenv)
    local tokens, err = tokenize(stripComments(body))
    if not tokens then
        writeRed(process.error(), "ksh: syntax error: " .. tostring(err), "\n")
        return "", 2
    end
    if #tokens == 0 then
        return "", 0
    end
    local text, status = captureSubshell(tokens, getenv)
    return (text:gsub("\n+$", "")), status
end

-- Gross.
local function expandCommandSubstitutions(str, getenv)
    local out = {}
    local lastStatus
    local i, n = 1, #str
    while i <= n do
        local nxt = str:find("['`$]", i) or n + 1
        if nxt > n then
            out[#out + 1] = str:sub(i)
            break
        end
        out[#out + 1] = str:sub(i, nxt - 1)
        local c = str:sub(nxt, nxt)
        if c == "'" then
            local close = str:find("'", nxt + 1, true)
            if not close then
                -- How did we get here
                out[#out + 1] = str:sub(nxt)
                break
            end
            out[#out + 1] = str:sub(nxt, close)
            i = close + 1
        elseif c == "`" then
            local close = str:find("`", nxt + 1, true)
            if not close then
                writeRed(process.error(), "ksh: unclosed `", "\n")
                return table.concat(out), lastStatus
            end
            local text, status = runCapture(str:sub(nxt + 1, close - 1), getenv)
            out[#out + 1] = text
            lastStatus = status
            i = close + 1
        else -- c == "$"
            if str:sub(nxt + 1, nxt + 1) == "(" then
                local close = matchParen(str, nxt + 1)
                if not close then
                    writeRed(process.error(), "ksh: missing ) to match (", "\n")
                    return table.concat(out), lastStatus
                end
                local text, status = runCapture(str:sub(nxt + 2, close - 1), getenv)
                out[#out + 1] = text
                lastStatus = status
                i = close + 1
            else
                out[#out + 1] = "$"
                i = nxt + 1
            end
        end
    end
    return table.concat(out), lastStatus
end

-- Todo: make even better
local function expandVars(str, getenv)
    local failMsg
    local subStatus
    -- subs go first!
    str, subStatus = expandCommandSubstitutions(str, getenv)
    local out = str:gsub("%$%b{}", function(tok)
        local body = tok:sub(3, -2)
        local name, op, arg = body:match("^([%a_][%w_]*):([%-=+?])(.*)$")
        if name then
            local result, err = applyOperator(name, op, arg, lookupVar(name, getenv))
            if err then failMsg = failMsg or err end
            return result or ""
        end
        if body == "?" then return tostring(st().lastExitCode) end
        if body == "$" then return tostring(shellPid or 0) end
        return lookupVar(body, getenv) or ""
    end)
    out = out:gsub("%$%?", tostring(st().lastExitCode))
    out = out:gsub("%$%$", tostring(shellPid or 0))
    out = out:gsub("%$([%d]+)", function(num)
        return lookupVar(num, getenv) or ""
    end)
    out = out:gsub("%$([#@*0])", function(sym)
        return lookupVar(sym, getenv) or ""
    end)
    out = out:gsub("%$([%a_][%w_]*)", function(name)
        return lookupVar(name, getenv) or ""
    end)
    return out, failMsg, subStatus
end

-- Fine il seperate them
local function expandToken(w, getenv)
    local isSingle = (#w >= 2 and w:sub(1, 1) == "'" and w:sub(-1) == "'")
    local isDouble = (#w >= 2 and w:sub(1, 1) == '"' and w:sub(-1) == '"')

    local inner = (isSingle or isDouble) and w:sub(2, -2) or w
    if isSingle then
        return inner, nil
    end

    local expanded, failMsg, subStatus = expandVars(inner, getenv)
    if not isDouble then
        if expanded == "~" or expanded:sub(1, 2) == "~/" then
            local home = getenv("HOME") or "/"
            expanded = home .. expanded:sub(2)
        end
    end
    return expanded, failMsg, subStatus
end

-- Text library is amazing
local function splitTokensOn(tokens, op)
    local groups, current = {}, {}
    for _, tok in ipairs(tokens) do
        if tok == op then
            groups[#groups + 1] = current
            current = {}
        else
            current[#current + 1] = tok
        end
    end
    groups[#groups + 1] = current
    return groups
end

-- Wildcard shenanigans are in shell for once
local function expandWildcard(str)
    if not (str:find("*") or str:find("?")) then
        return { str }
    end

    local dirPrefix, pat
    if str:find("/") then
        dirPrefix = filesystem.path(str)
        pat = filesystem.name(str)
    else
        dirPrefix = ""
        pat = str
    end

    local searchDir = (dirPrefix == "") and st().currPath or resolvePath(st().currPath, dirPrefix)
    if not filesystem.exists(searchDir) or not filesystem.isDirectory(searchDir) then
        return { str }
    end

    -- I do not know why the carrot is called pat.
    -- Not my code anyway but its nice
    local luaPat = "^"
    for idx = 1, #pat do
        local c = pat:sub(idx, idx)
        if c == "*" then
            luaPat = luaPat .. ".*"
        elseif c == "?" then
            luaPat = luaPat .. "."
        elseif c:match("%W") then
            luaPat = luaPat .. "%" .. c
        else
            luaPat = luaPat .. c
        end
    end
    luaPat = luaPat .. "$"

    local patStartsWithDot = (pat:sub(1, 1) == ".")
    local matches = {}

    for entry in filesystem.list(searchDir) do
        local name = filesystem.canonical(entry)
        if name ~= "." and name ~= ".." then
            local isHidden = (name:sub(1, 1) == ".")
            if not isHidden or patStartsWithDot then
                if name:match(luaPat) then
                    local fullMatch
                    if dirPrefix == "/" then
                        fullMatch = "/" .. name
                    elseif dirPrefix ~= "" then
                        fullMatch = dirPrefix .. name
                    else
                        fullMatch = name
                    end
                    table.insert(matches, fullMatch)
                end
            end
        end
    end

    if #matches == 0 then
        return { str }
    end

    table.sort(matches)
    return matches
end

-- deals with redirection
local function parseSegment(words, getenv)
    if #words == 0 then
        return nil, "empty command"
    end

    -- Alias expansion (a subshell group is never an alias)
    local maxDepth = 10
    while maxDepth > 0 and type(words[1]) == "string" and st().aliases[words[1]] do
        maxDepth = maxDepth - 1
        local aliasVal = st().aliases[words[1]]
        if aliasVal:find("%$%d") or aliasVal:find("%$%@") or aliasVal:find("%$%*") then
            local restArgs = {}
            for k = 2, #words do restArgs[#restArgs + 1] = words[k] end
            local expanded = aliasVal:gsub("%$%d+", function(m)
                local idx = tonumber(m:sub(2))
                return restArgs[idx] or ""
            end):gsub("%$%@", table.concat(restArgs, " ")):gsub("%$%*", table.concat(restArgs, " "))
            local newToks, err = tokenize(expanded)
            if not newToks then return nil, err end
            words = newToks
            break
        else
            local aliasWords, err = tokenize(aliasVal)
            if not aliasWords then return nil, err end
            local newWords = {}
            for _, w in ipairs(aliasWords) do newWords[#newWords + 1] = w end
            for k = 2, #words do newWords[#newWords + 1] = words[k] end
            words = newWords
        end
    end

    local args = {}
    local redirects = { stdinFile = nil, stdoutFile = nil, appendOut = false, fdRedirects = {} }
    local i = 1
    local expandFail
    local subshell

    local function dealWithToken(w)
        local isQuoted = (#w >= 2) and
            ((w:sub(1, 1) == '"' and w:sub(-1) == '"') or (w:sub(1, 1) == "'" and w:sub(-1) == "'"))
        local expanded, failMsg, subStatus = expandToken(w, getenv)
        expandFail = expandFail or failMsg
        if isQuoted then return { expanded } end
        if subStatus ~= nil then
            -- unquoted?
            local fields = {}
            for field in expanded:gmatch("%S+") do
                fields[#fields + 1] = field
            end
            if #fields == 0 then return {} end
            local out = {}
            for _, f in ipairs(fields) do
                local matches = expandWildcard(f)
                for _, m in ipairs(matches) do out[#out + 1] = m end
            end
            return out
        end
        return expandWildcard(expanded)
    end

    -- (thing) is the one itself
    if type(words[1]) == "table" and words[1].subshell then
        subshell = words[1].subshell
        i = 2
    end

    while i <= #words do
        local w = words[i]
        if type(w) == "table" then
            return nil, "syntax error near '('"
        elseif w == "<" then
            if type(words[i + 1]) ~= "string" then return nil, "missing filename after <" end
            redirects.stdinFile = dealWithToken(words[i + 1])[1]
            i = i + 2
        elseif w == ">" then
            if type(words[i + 1]) ~= "string" then return nil, "missing filename after >" end
            redirects.stdoutFile = dealWithToken(words[i + 1])[1]
            redirects.appendOut = false
            i = i + 2
        elseif w == ">>" then
            if type(words[i + 1]) ~= "string" then return nil, "missing filename after >>" end
            redirects.stdoutFile = dealWithToken(words[i + 1])[1]
            redirects.appendOut = true
            i = i + 2
        else
            -- &N> &N>> &N< and N> N>> N< fd this is not even a finished list
            local fd, op = w:match("^&(%d+)(>>?)$")
            if not fd then fd, op = w:match("^&(%d+)(<)$") end
            if not fd then fd, op = w:match("^(%d+)(>>?)$") end
            if not fd then fd, op = w:match("^(%d+)(<)$") end

            if fd then
                fd = tonumber(fd)
                if type(words[i + 1]) ~= "string" then return nil, "missing filename after " .. w end
                local rawTarget = words[i + 1]
                -- &N works for real
                local aliasFd = rawTarget:match("^&(%d+)$")

                if aliasFd then
                    aliasFd = tonumber(aliasFd)
                    redirects.fdAliases = redirects.fdAliases or {}
                    redirects.fdAliases[fd] = aliasFd
                else
                    local target = dealWithToken(rawTarget)[1]
                    if fd == 0 or op == "<" then
                        redirects.stdinFile = target
                    elseif fd == 1 then
                        redirects.stdoutFile = target
                        redirects.appendOut = (op == ">>")
                    elseif fd == 2 then
                        redirects.stderrFile = target
                        redirects.appendStderr = (op == ">>")
                    else
                        redirects.fdRedirects[fd] = {
                            file = target,
                            append = (op == ">>"),
                            mode = (op == "<") and "r" or
                                "w"
                        }
                    end
                end
                i = i + 2
            else
                if subshell then
                    return nil, "syntax error: unexpected word after ( list )"
                end
                local expandedList = dealWithToken(w)
                for _, item in ipairs(expandedList) do
                    args[#args + 1] = item
                end
                i = i + 1
            end
        end
    end

    if #args == 0 and not subshell then
        return nil, "empty command"
    end

    if expandFail then
        return nil, expandFail, true
    end

    if subshell then
        return { subshell = subshell, redirects = redirects }
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

-- error reason: path
local function ioErr(reason, path)
    return tostring(reason) .. ": " .. path
end

-- Where should they go?
local function ownStdin()
    if inSubshell() then
        local desc = process.input()
        return {
            read = function(_, ...) return desc:read(...) end,
            readLine = function(_, ...) return desc:readLine(...) end,
            close = function() end,
        }
    end
    return ttyInPassthrough()
end

local function ownStdout()
    if inSubshell() then
        local desc = process.output()
        return {
            write = function(_, ...) return desc:write(...) end,
            flush = function() return desc:flush() end,
            close = function() end,
        }
    end
    return ttyOutPassthrough()
end

local function ownStderr()
    if inSubshell() then
        local desc = process.error()
        return {
            write = function(_, ...) return desc:write(...) end,
            flush = function() return desc:flush() end,
            close = function() end,
        }
    end
    return ttyOutPassthrough()
end

-- Decides fd0/1/2 or tty
local function makeStreams(inPipe, outPipe, redirects)
    local stdin, stdout, stderr

    if redirects.stdinFile then
        local full = resolvePath(st().currPath, redirects.stdinFile)
        if not filesystem.exists(full) then
            return nil, nil, nil, ioErr("no such file or directory", redirects.stdinFile)
        end
        if filesystem.isDirectory(full) then
            return nil, nil, nil, ioErr("is a directory", redirects.stdinFile)
        end
        local stream, reason = io.newFileStream(full, "r")
        if not stream then return nil, nil, nil, ioErr(reason, redirects.stdinFile) end
        stdin = stream
    else
        stdin = inPipe or ownStdin()
    end

    if redirects.stdoutFile then
        local full = resolvePath(st().currPath, redirects.stdoutFile)
        if filesystem.isDirectory(full) then
            return nil, nil, nil, ioErr("is a directory", redirects.stdoutFile)
        end
        local stream, reason = openForOutput(full, redirects.appendOut)
        if not stream then return nil, nil, nil, ioErr(reason, redirects.stdoutFile) end
        stdout = stream
    else
        stdout = outPipe or ownStdout()
    end

    if redirects.stderrFile then
        local full = resolvePath(st().currPath, redirects.stderrFile)
        if filesystem.isDirectory(full) then
            return nil, nil, nil, ioErr("is a directory", redirects.stderrFile)
        end
        local stream, reason = openForOutput(full, redirects.appendStderr)
        if not stream then return nil, nil, nil, ioErr(reason, redirects.stderrFile) end
        stderr = stream
    else
        stderr = ownStderr()
    end

    -- Yay fd aliasing
    if redirects.fdAliases then
        local resolved = { [0] = stdin, [1] = stdout, [2] = stderr }
        for dst, src in pairs(redirects.fdAliases) do
            local stream = resolved[src]
            if not stream then
                return nil, nil, nil, "bad file descriptor: &" .. src
            end
            if dst == 0 then
                stdin = stream
            elseif dst == 1 then
                stdout = stream
            elseif dst == 2 then
                stderr = stream
            end
        end
    end

    return stdin, stdout, stderr
end

-- Now with $PATH
local function resolveCommand(name, getenv)
    -- Direct path
    if name:find("/") then
        local full = resolvePath(st().currPath, name)
        if filesystem.exists(full) and not filesystem.isDirectory(full) then
            return full
        end
        if filesystem.exists(full .. ".lua") and not filesystem.isDirectory(full .. ".lua") then
            return full .. ".lua"
        end
        return nil
    end

    -- Lookup by PATH
    local pathStr = lookupVar("PATH", getenv)
    if not pathStr or pathStr == "" then
        pathStr = "/bin:/sbin"
    end

    -- Keep looking
    for dir in pathStr:gmatch("[^:]+") do
        local searchDir = resolvePath(st().currPath, dir)
        local candidate = filesystem.concat(searchDir, name)

        if filesystem.exists(candidate) and not filesystem.isDirectory(candidate) then
            return candidate
        end
        if filesystem.exists(candidate .. ".lua") and not filesystem.isDirectory(candidate .. ".lua") then
            return candidate .. ".lua"
        end
    end

    return nil
end

-- Runs pipeline
local function runPipeline(parsedSegments, tempAssigns, getenv)
    local segCount = #parsedSegments
    local pipes = {}
    for i = 1, segCount - 1 do
        pipes[i] = io.newPipe(polaris.scheduler, 8192)
    end

    local results = {}
    local remaining = segCount
    local waiterPid = process.self().pid
    local spawnedAny = false
    local pids = {}

    local spawnPwd = st().currPath
    local spawnGid = st().gid

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
            -- I hate double draw bug. Go away.
            if spawnedAny then
                process.send(waiterPid, true)
            end
        end
    end

    local tempEnvValues
    if tempAssigns then
        tempEnvValues = {}
        for _, a in ipairs(tempAssigns) do
            tempEnvValues[a.name] = st().locals[a.name]
        end
    end

    for segIdx = 1, segCount do
        local seg = parsedSegments[segIdx]
        local inPipe = pipes[segIdx - 1]
        local outPipe = pipes[segIdx]
        local subshell = seg.subshell
        local cmdName = seg.args and seg.args[1]
        local builtin = not subshell and builtins[cmdName]
        local resolved = not builtin and not subshell and resolveCommand(cmdName, getenv)

        if not subshell and not builtin and not resolved then
            writeRed(process.error(), "ksh: command not found: " .. tostring(cmdName), "\n")
            segmentDone(segIdx, 127, inPipe, outPipe)
        else
            local stdin, stdout, stderr, err = makeStreams(inPipe, outPipe, seg.redirects)

            if err then
                writeRed(process.error(), "ksh: " .. err, "\n")
                segmentDone(segIdx, 1, inPipe, outPipe)
            else
                spawnedAny = true

                if subshell then
                    local pid = spawnSubshell(subshell, {
                        stdin = stdin,
                        stdout = stdout,
                        stderr = stderr,
                        gid = spawnGid,
                        tempEnv = (segIdx == 1) and tempEnvValues or nil,
                        cmd = "( subshell )",
                        label = "( subshell )",
                        onExit = function(success, exitCode)
                            local code = (type(exitCode) == "number") and exitCode
                                or (success and 0 or 1)
                            segmentDone(segIdx, code, inPipe, outPipe)
                        end,
                    })
                    pids[#pids + 1] = pid
                else
                    local pid
                    pid = process.spawn(function()
                        local env = polaris.env.current()
                        env.console = makeConsole(spawnPwd)
                        env.args = argv(seg.args)
                        env.ctty = tty -- current tty, I am too lazy to deal with /dev/tty* bs and this is far easier for me
                        env.setenv("PWD", spawnPwd)
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
                        cmd = resolved,
                        label = seg.args[1],
                        gid = spawnGid,
                        ppid = shellPid,
                        onExit = function(success, exitCode)
                            -- Go away fd table
                            process.destroy(pid)
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
    end

    -- Deal with this weirdness
    if spawnedAny and remaining > 0 then
        st().fgBusy = true
        -- Yes, I loop here because multiple SIGCHLDs can arrive. Lazy I know. no, I will not queue signals as promised. Go away
        while remaining > 0 do
            process.waitForInput()
        end
        st().fgBusy = false
        tty:flush()
        if tty.cx > 1 then
            tty:write("\n")
        end
    end

    st().lastExitCode = results[segCount] or st().lastExitCode
end

-- Deals with subshell stuff

-- Copies the shell's environment
local function snapshotState(gid)
    local s = st()
    local copy = {
        locals = {},
        scriptArgs = s.scriptArgs,
        aliases = {},
        currPath = s.currPath,
        lastExitCode = s.lastExitCode,
        fgBusy = false,
        gid = gid or s.gid,
        asyncJobs = {},
    }
    for k, v in pairs(s.locals) do copy.locals[k] = v end
    for k, v in pairs(s.aliases) do copy.aliases[k] = v end
    return copy
end

-- I wonder what this does
spawnSubshell = function(tokens, opts)
    opts = opts or {}
    local state = snapshotState(opts.gid)
    if opts.scriptArgs ~= nil then
        state.scriptArgs = opts.scriptArgs
    end
    local tempEnv = opts.tempEnv
    local pid
    pid = process.spawn(function()
        -- Private state from here on
        shellStates[process.activeThread()] = state
        local env = polaris.env.current()
        if tempEnv then
            for name, value in pairs(tempEnv) do
                env.setenv(name, value)
            end
        end
        local ok, err = xpcall(function()
            if opts.script then
                runScriptLines(opts.script, env.getenv)
            else
                executeTokens(tokens, env.getenv)
            end
        end, debug.traceback)
        if not ok then
            pcall(function()
                process.error():write("\27[31m", tostring(err), "\n\27[0m")
            end)
            process.exit(1)
        end
        -- Deal with output in buffer still
        pcall(function() process.output():flush() end)
        process.exit(state.lastExitCode)
    end, {
        cmd = opts.cmd or "( subshell )",
        label = opts.label or "( subshell )",
        gid = state.gid,
        ppid = shellPid,
        onExit = function(success, exitCode)
            -- Fix
            process.destroy(pid)
            shellStates[pid] = nil
            if tty.detach then
                tty:detach(pid)
            end
            if opts.onExit then
                opts.onExit(success, exitCode)
            end
        end,
    })
    process.create(pid, opts.stdin or ownStdin(), opts.stdout or ownStdout(),
        opts.stderr or ownStderr())
    if tty.attach then
        tty:attach(pid)
    end
    return pid
end

-- Substitution stuff
captureSubshell = function(tokens, getenv)
    local pipe = io.newPipe(polaris.scheduler, 8192)
    local status = 0
    spawnSubshell(tokens, {
        stdout = pipe,
        cmd = "$( subshell )",
        label = "$( subshell )",
        onExit = function(success, exitCode)
            status = (type(exitCode) == "number") and exitCode or (success and 0 or 1)
        end,
    })
    st().fgBusy = true
    local chunks = {}
    while true do
        local chunk, why = pipe:read()
        if chunk then
            chunks[#chunks + 1] = chunk
        elseif why then
        else
            break -- EOF
        end
    end
    st().fgBusy = false
    pipe:closeRead()
    return table.concat(chunks), status
end

-- Runs something in background, this is not finished!
local function runAsync(tokens, getenv)
    local spawnerPid = process.activeThread()
    local job = { pid = nil, done = false, status = 0 }
    job.pid = spawnSubshell(tokens, {
        gid = process.GID.BG,
        stdin = io.newStream(),
        cmd = "async list",
        label = "async list",
        onExit = function(success, exitCode)
            job.done = true
            job.status = (type(exitCode) == "number") and exitCode or (success and 0 or 1)
            -- Wake a pending wait
            process.send(spawnerPid, true)
        end,
    })
    local jobs = st().asyncJobs
    jobs[#jobs + 1] = job
    st().lastExitCode = 0
end

-- scripting in subshell?
local function runScriptSubshell(path, argsTable)
    local full = resolvePath(st().currPath, path)
    if not filesystem.exists(full) then
        writeRed(process.error(), "sh: " .. ioErr("no such file or directory", path), "\n")
        return 1
    end
    if filesystem.isDirectory(full) then
        writeRed(process.error(), "sh: " .. ioErr("is a directory", path), "\n")
        return 1
    end
    local waiterPid = process.activeThread()
    local status = 0
    local done = false
    spawnSubshell(nil, {
        script = full,
        scriptArgs = argsTable,
        cmd = "sh " .. path,
        label = "sh script",
        onExit = function(success, exitCode)
            status = (type(exitCode) == "number") and exitCode or (success and 0 or 1)
            done = true
            process.send(waiterPid, true)
        end,
    })

    st().fgBusy = true
    -- Lazy some more
    while not done do
        process.waitForInput()
    end
    st().fgBusy = false
    tty:flush()
    if tty.cx > 1 then
        tty:write("\n")
    end
    return status
end

-- Shell builtins are sane

-- exit, why so weird?
function builtins.exit(args)
    local code = st().lastExitCode
    if args and args[1] then
        code = math.floor(tonumber(args[1]) or code)
    end
    if code < 0 then code = 0 end
    process.exit(code)
end

function builtins.clear()
    tty:clear()
end

function builtins.cd(args, _, _, _)
    local env = polaris.env.current()

    local target = args[1] or env.getenv("HOME") or "/"
    local full = resolvePath(st().currPath, target)
    if not filesystem.exists(full) then
        writeRed(process.error(), "cd: no such directory: " .. target, "\n")
        st().lastExitCode = 1
        return
    end
    if not filesystem.isDirectory(full) then
        writeRed(process.error(), "cd: not a directory: " .. target, "\n")
        st().lastExitCode = 1
        return
    end
    st().currPath = full
    st().lastExitCode = 0
end

-- Echo echo echo...
builtins["echo"] = function(args, stdin, stdout, stderr)
    local noNewline = false
    local interpretEscapes = false
    local words = {}

    local i = 1

    -- No need for getopt
    while i <= #args do
        local arg = args[i]

        if arg == "-n" then
            noNewline = true
        elseif arg == "-e" then
            interpretEscapes = true
        elseif arg == "-ne" or arg == "-en" then
            noNewline = true
            interpretEscapes = true
        elseif arg == "--" then
            i = i + 1
            while i <= #args do
                words[#words + 1] = args[i]
                i = i + 1
            end
            break
        else
            words[#words + 1] = arg
        end

        i = i + 1
    end

    local line = table.concat(words, " ")

    if interpretEscapes then
        -- Some basic stuff
        local escapes = {
            ["\\"] = "\\",
            ["a"] = "\7",
            ["b"] = "\b",
            ["f"] = "\f",
            ["n"] = "\n",
            ["r"] = "\r",
            ["t"] = "\t",
            ["v"] = "\v",
            ["e"] = "\27",
            ["E"] = "\27",
        }

        line = line:gsub("\\([\\abefnrtvE])", function(c)
            return escapes[c]
        end)

        -- \xNN hex (WHY WOULD YOU USE THIS)
        line = line:gsub("\\x(%x%x)", function(hex)
            local n = tonumber(hex, 16)
            return n and string.char(n) or ("\x00" .. hex)
        end)

        -- \uNNNN unicode
        line = line:gsub("\\u(%x%x%x%x)", function(hex)
            local n = tonumber(hex, 16)
            return n and unicode.char(n) or ("\\u" .. hex)
        end)

        -- \UNNNNNNNN more unicode
        line = line:gsub("\\U(%x%x%x%x%x%x%x%x)", function(hex)
            local n = tonumber(hex, 16)
            return n and unicode.char(n) or ("\\U" .. hex)
        end)

        -- \0NNN octal
        line = line:gsub("\\0(%d%d?%d?)", function(octal)
            local n = tonumber(octal, 8)
            return n and string.char(n) or ("\0" .. octal)
        end)
    end

    stdout:write(line)

    if not noNewline then
        stdout:write("\n")
    else
        stdout:flush()
    end

    st().lastExitCode = 0
end

builtins["pwd"] = function(args, stdin, stdout, stderr)
    stdout:write(st().currPath, "\n")
    st().lastExitCode = 0
end

-- hey local variable, congratulations on migrating
builtins["export"] = function(args, stdin, stdout, stderr)
    local env = polaris.env.current()

    if #args == 0 then
        for k, v in pairs(env.getall()) do
            stdout:write(k .. "=" .. tostring(v), "\n")
        end
        st().lastExitCode = 0
        return
    end

    for _, arg in ipairs(args) do
        local name, value = arg:match("^([%a_][%w_]*)=(.*)$")
        if name then
            st().locals[name] = nil
            env.setenv(name, value)
        else
            env.setenv(arg, st().locals[arg] or env.getenv(arg))
            st().locals[arg] = nil
        end
    end
    st().lastExitCode = 0
end

-- goodbye variable
builtins["unset"] = function(args, stdin, stdout, stderr)
    local env = polaris.env.current()
    for _, name in ipairs(args) do
        st().locals[name] = nil
        env.setenv(name, nil)
    end
    st().lastExitCode = 0
end

-- set hopefully works
builtins["set"] = function(args, stdin, stdout, stderr)
    if #args == 0 then
        local env = polaris.env.current()
        local seen = {}
        for k, v in pairs(env.getall()) do
            stdout:write(k .. "=" .. tostring(v), "\n")
            seen[k] = true
        end
        for k, v in pairs(st().locals) do
            if not seen[k] then
                stdout:write(k .. "=" .. tostring(v), "\n")
            end
        end
        st().lastExitCode = 0
        return
    end

    for _, arg in ipairs(args) do
        local name, value = arg:match("^([%a_][%w_]*)=(.*)$")
        if name then
            st().locals[name] = value
        end
    end
    st().lastExitCode = 0
end
-- omg aliasing finally
builtins["alias"] = function(args, stdin, stdout, stderr)
    if #args == 0 then
        for k, v in pairs(st().aliases) do
            stdout:write("alias " .. k .. "='" .. v .. "'\n")
        end
        st().lastExitCode = 0
        return
    end
    for _, arg in ipairs(args) do
        local name, val = arg:match("^([%w_%-]+)=(.*)$")
        if name then
            st().aliases[name] = stripQuotes(val)
        else
            if st().aliases[arg] then
                stdout:write("alias " .. arg .. "='" .. st().aliases[arg] .. "'\n")
            else
                writeRed(process.error(), "alias: " .. arg .. ": not found\n")
                st().lastExitCode = 1
                return
            end
        end
    end
    st().lastExitCode = 0
end

builtins["unalias"] = function(args, stdin, stdout, stderr)
    for _, arg in ipairs(args) do
        st().aliases[arg] = nil
    end
    st().lastExitCode = 0
end

builtins["type"] = function(args, stdin, stdout, stderr)
    if #args == 0 then
        st().lastExitCode = 0
        return
    end

    local env = polaris.env.current()
    local hasError = false
    for _, name in ipairs(args) do
        if st().aliases[name] then
            stdout:write(name .. " is an alias for " .. st().aliases[name] .. "\n")
        elseif builtins[name] then
            stdout:write(name .. " is a shell builtin\n")
        else
            local cmdPath = resolveCommand(name, env.getenv)
            if cmdPath then
                stdout:write(name .. " is " .. cmdPath .. "\n")
            else
                stderr:write("ksh: type: " .. name .. ": not found\n")
                hasError = true
            end
        end
    end

    st().lastExitCode = hasError and 1 or 0
end

builtins["true"] = function(args, stdin, stdout, stderr)
    st().lastExitCode = 0
end

builtins["false"] = function(args, stdin, stdout, stderr)
    st().lastExitCode = 1
end

builtins["kill"] = function(args, stdin, stdout, stderr)
    local sig = "INT" -- default
    local sigNum = 2
    local targets = {}
    local i = 1

    -- -l
    if args[1] == "-l" then
        local nums = {}

        for n, name in pairs(process.SIG) do
            if type(n) == "number" and type(name) == "string" then
                nums[#nums + 1] = n
            end
        end

        table.sort(nums)

        for _, n in ipairs(nums) do
            stdout:write(n .. ") SIG" .. process.SIG[n] .. "\n")
        end

        st().lastExitCode = 0
        return
    end

    while i <= #args do
        local a = args[i]

        if a == "-s" then
            i = i + 1
            local tok = args[i]

            if not tok then
                stderr:write("kill: -s requires a signal name\n")
                st().lastExitCode = 1
                return
            end

            local n = tonumber(tok) or process.SIG[tok:upper()]

            if type(n) ~= "number" then
                stderr:write("kill: unknown signal: " .. tok .. "\n")
                st().lastExitCode = 1
                return
            end

            if not process.SIG[n] then
                stderr:write("kill: unknown signal: " .. tok .. "\n")
                st().lastExitCode = 1
                return
            end

            sigNum = n
            sig = process.SIG[n]
        elseif a == "-n" then
            i = i + 1
            local tok = args[i]
            local n = tok and tonumber(tok)

            if not n or not process.SIG[n] then
                stderr:write("kill: -n requires a valid signal number\n")
                st().lastExitCode = 1
                return
            end

            sigNum = n
            sig = process.SIG[n]
        elseif a:sub(1, 1) == "-" and #a > 1 then
            -- -SIGNAME or -NUM
            local tok = a:sub(2)
            local n = tonumber(tok) or process.SIG[tok:upper()]

            if type(n) ~= "number" then
                stderr:write("kill: unknown signal: " .. tok .. "\n")
                st().lastExitCode = 1
                return
            end

            if not process.SIG[n] then
                stderr:write("kill: unknown signal: " .. tok .. "\n")
                st().lastExitCode = 1
                return
            end

            sigNum = n
            sig = process.SIG[n]
        elseif a:sub(1, 1) == "%" then
            -- jobs for when I get around to it
            stderr:write("kill: Jobs not implemented\n")
            st().lastExitCode = 1
            return
        else
            targets[#targets + 1] = a
        end

        i = i + 1
    end

    if #targets == 0 then
        stderr:write("kill: usage: kill [-s sig|-n num|-SIG] pid ...\n")
        st().lastExitCode = 1
        return
    end

    local ok = true

    for _, t in ipairs(targets) do
        local pid = tonumber(t)

        if not pid then
            stderr:write("kill: invalid pid: " .. t .. "\n")
            ok = false
        elseif not process.exists(pid) then
            stderr:write("kill: no such process: " .. t .. "\n")
            ok = false
        else
            local sent = process.signal(pid, process.SIG[sig])
            if not sent then
                stderr:write("kill: operation not permitted for pid: " .. t .. "\n")
                ok = false
            end
        end
    end

    st().lastExitCode = ok and 0 or 1
end

builtins["read"] = function(args, stdin, stdout, stderr)
    local raw = false
    local silent = false
    local varNames = {}

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-r" then
            raw = true
        elseif a == "-s" then
            silent = true
        elseif a == "-rs" or a == "-sr" then
            raw = true
            silent = true
        elseif a:sub(1, 1) == "-" then
            stderr:write("ksh: read: " .. a .. ": invalid option\n")
            st().lastExitCode = 1
            return
        else
            varNames[#varNames + 1] = a
        end
        i = i + 1
    end

    if #varNames == 0 then
        varNames[1] = "REPLY"
    end

    -- -s
    local prevEcho
    if silent and tty then
        prevEcho = tty.attributes.echo
        tty.attributes.echo = false
    end

    local line = stdin:readLine()
    if line == nil then
        st().lastExitCode = 1
        return
    end
    line = line:gsub("\n$", "")

    if silent and tty then
        tty.attributes.echo = prevEcho
        --tty:write("\n")
        tty:flush()
    end

    -- EOF
    if line == nil then
        st().lastExitCode = 1
        return
    end

    -- -r
    if not raw then
        line = line:gsub("\\\n", "")
        line = line:gsub("\\(.)", "%1")
    end

    local env = polaris.env.current()

    if #varNames == 1 then
        st().locals[varNames[1]] = line
        env.setenv(varNames[1], line)
    else
        local parts = {}
        for word in line:gmatch("%S+") do
            parts[#parts + 1] = word
        end
        for idx, name in ipairs(varNames) do
            if idx < #varNames then
                st().locals[name] = parts[idx] or ""
                env.setenv(name, parts[idx] or "")
            else
                local rest = table.concat(parts, " ", idx)
                st().locals[name] = rest
                env.setenv(name, rest)
            end
        end
    end

    st().lastExitCode = 0
end

-- Background jobs broken! But I added them with subshells
builtins["wait"] = function(args, stdin, stdout, stderr)
    local jobs = st().asyncJobs

    local function waitJob(job)
        if not job.done then
            st().fgBusy = true
            while not job.done do
                process.waitForInput()
            end
            st().fgBusy = false
        end
        return job.status
    end

    if #args == 0 then
        for _, job in ipairs(jobs) do
            waitJob(job)
        end
        st().asyncJobs = {}
        st().lastExitCode = 0
        return
    end

    for _, arg in ipairs(args) do
        local pid = tonumber(arg)
        local job
        for _, j in ipairs(jobs) do
            if j.pid == pid then
                job = j
                break
            end
        end
        if not job then
            stderr:write("ksh: wait: " .. tostring(arg) .. ": not an async job of this shell\n")
            st().lastExitCode = 127
        else
            st().lastExitCode = waitJob(job)
        end
    end
end

-- The input

-- Mmmm lists, returns them
local function splitAssignments(words)
    local assigns = {}
    local i = 1
    while words[i] do
        if type(words[i]) ~= "string" then break end
        local name, value = stripQuotes(words[i]):match("^([%a_][%w_]*)=(.*)$")
        if not name then break end
        -- Cheap
        if value == "" and type(words[i + 1]) == "string"
            and words[i + 1]:sub(1, 2) == "$(" then
            value = words[i + 1]
            i = i + 1
        end
        assigns[#assigns + 1] = { name = name, value = value }
        i = i + 1
    end
    local rest = {}
    for j = i, #words do
        rest[#rest + 1] = words[j]
    end
    return assigns, rest
end

-- Everything but && and ;
local function runCommandGroup(words, getenv)
    local assigns, rest = splitAssignments(words)

    if #assigns > 0 and #rest == 0 then
        -- $?
        local status = 0
        for _, a in ipairs(assigns) do
            local value, _, subStatus = expandToken(a.value, getenv)
            st().locals[a.name] = value
            if subStatus ~= nil then
                status = subStatus
            end
        end
        st().lastExitCode = status
        return
    end

    local saved
    local savedNames
    if #assigns > 0 then
        saved = {}
        savedNames = {}
        for _, a in ipairs(assigns) do
            saved[a.name] = st().locals[a.name]
            savedNames[#savedNames + 1] = a.name
            st().locals[a.name] = expandToken(a.value, getenv)
        end
        words = rest
    end

    local function restoreLocals()
        if not savedNames then return end
        for _, name in ipairs(savedNames) do
            st().locals[name] = saved[name]
        end
    end

    local pipeGroups = splitTokensOn(words, "|")
    local parsed = {}

    for _, segTokens in ipairs(pipeGroups) do
        local seg, err, isParamError = parseSegment(segTokens, getenv)
        if not seg then
            if isParamError then
                writeRed(process.error(), "ksh: " .. err, "\n")
                st().lastExitCode = 1
            else
                writeRed(process.error(), "ksh: syntax error: " .. err, "\n")
                st().lastExitCode = 2
            end
            restoreLocals()
            return
        end
        parsed[#parsed + 1] = seg
    end

    -- Shell process has builtins except a ( list ) is always a subshell
    local first = parsed[1].args and parsed[1].args[1]

    if #parsed == 1 and first and builtins[first] then
        local seg = parsed[1]

        local stdin, stdout, stderr, err = makeStreams(nil, nil, seg.redirects)

        if err then
            writeRed(process.error(), "ksh: " .. err, "\n")
            st().lastExitCode = 1
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
            writeRed(process.error(), tostring(builtinErr), "\n")
            st().lastExitCode = 1
        end

        restoreLocals()
        return
    end

    runPipeline(parsed, saved and assigns, getenv)
    restoreLocals()
end

-- This is incredibly lazy but is for $( subshell ) syntax
local function extractSubshells(tokens)
    local out = {}
    local i = 1
    local n = #tokens
    while i <= n do
        local tok = tokens[i]
        if type(tok) == "string" and not tokenIsQuoted(tok) then
            if tok == "(" or tok == "$(" then
                local isGroup = (tok == "(")
                local depth = 1
                local inner = {}
                local j = i + 1
                while j <= n do
                    local t = tokens[j]
                    if type(t) == "string" and not tokenIsQuoted(t) then
                        if t == "(" or t == "$(" then
                            depth = depth + 1
                            inner[#inner + 1] = t
                            j = j + 1
                        elseif t == ")" then
                            depth = depth - 1
                            if depth == 0 then break end
                            inner[#inner + 1] = t
                            j = j + 1
                        else
                            inner[#inner + 1] = t
                            j = j + 1
                        end
                    else
                        inner[#inner + 1] = t
                        j = j + 1
                    end
                end
                if depth ~= 0 then
                    return nil, "missing )"
                end
                if isGroup then
                    if #inner == 0 then
                        return nil, "syntax error: empty ( list )"
                    end
                    out[#out + 1] = { subshell = inner }
                else
                    out[#out + 1] = "$(" .. table.concat(inner, " ") .. ")"
                end
                i = j + 1
            elseif tok == ")" then
                return nil, "syntax error near ')'"
            else
                out[#out + 1] = tok
                i = i + 1
            end
        else
            out[#out + 1] = tok
            i = i + 1
        end
    end
    return out
end

-- Chains hopefully dont barrel through anymore
local function runAndList(tokens, getenv)
    local groups = splitTokensOn(tokens, "&&")
    for _, groupTokens in ipairs(groups) do
        if #groupTokens == 0 then
            writeRed(process.error(), "ksh: syntax error near '&&'", "\n")
            st().lastExitCode = 2
            return
        end

        runCommandGroup(groupTokens, getenv)

        if st().lastExitCode ~= 0 then
            -- && skip
            return
        end
    end
end

-- Runs a list of stuff
executeTokens = function(rawTokens, getenv)
    local tokens, err = extractSubshells(rawTokens)
    if not tokens then
        writeRed(process.error(), "ksh: syntax error: " .. tostring(err), "\n")
        st().lastExitCode = 2
        return
    end

    local parts = {}
    local terms = {}
    local cur = {}
    for _, tok in ipairs(tokens) do
        if type(tok) == "string" and tok:sub(1, 1) == "#" then
            break -- comment token (line level already stripped these)
        elseif tok == "&" or tok == ";" then
            if #cur == 0 then
                writeRed(process.error(), "ksh: syntax error near '" .. tok .. "'", "\n")
                st().lastExitCode = 2
                return
            end
            parts[#parts + 1] = cur
            terms[#parts] = tok
            cur = {}
        else
            cur[#cur + 1] = tok
        end
    end
    if #cur > 0 then
        parts[#parts + 1] = cur
        terms[#parts] = nil
    end

    for i, part in ipairs(parts) do
        if terms[i] == "&" then
            runAsync(part, getenv)
        else
            runAndList(part, getenv)
        end
    end
end

local function executeLine(line, getenv)
    line = line:gsub("[\r\n]+$", "")
    line = stripComments(line)
    if line:match("^%s*$") then return end

    local tokens, err = tokenize(line)
    if not tokens then
        writeRed(process.error(), "ksh: syntax error: " .. tostring(err), "\n")
        st().lastExitCode = 2
        return
    end
    if #tokens == 0 then return end

    executeTokens(tokens, getenv)
end

-- I am lazy so we just natively source stuff
local function sourceFile(path, getenv)
    local full = resolvePath(st().currPath, path)
    if not filesystem.exists(full) then return end
    if filesystem.isDirectory(full) then
        writeRed(process.error(), "ksh: " .. ioErr("is a directory", path), "\n")
        return
    end
    local f, reason = io.newFileStream(full, "r")
    if not f then
        writeRed(process.error(), "ksh: " .. ioErr(reason, path), "\n")
        return
    end
    local buf = {}
    while true do
        local chunk = f:read(math.huge)
        if not chunk then break end
        buf[#buf + 1] = chunk
    end
    f:close()
    for line in table.concat(buf):gmatch("[^\n]+") do
        executeLine(line, getenv)
    end
end

-- Scripts always go here
runScriptLines = function(full, getenv)
    local f, reason = io.newFileStream(full, "r")
    if not f then
        error(ioErr(reason, full), 0)
    end
    local buf = {}
    while true do
        local chunk = f:read(math.huge)
        if not chunk then break end
        buf[#buf + 1] = chunk
    end
    f:close()
    for line in table.concat(buf):gmatch("[^\n]+") do
        executeLine(line, getenv)
    end
    return st().lastExitCode
end

-- Run and go die
local function runScript(path, getenv)
    local full = resolvePath(st().currPath, path)
    if not filesystem.exists(full) then
        writeRed(process.error(), "ksh: " .. ioErr("no such file or directory", path), "\n")
        process.exit(1)
    end
    if filesystem.isDirectory(full) then
        writeRed(process.error(), "ksh: " .. ioErr("is a directory", path), "\n")
        process.exit(1)
    end
    runScriptLines(full, getenv)
    process.exit(st().lastExitCode)
end

-- "Hey why are builtins so low down" its because im lazy
builtins["sh"] = function(args, stdin, stdout, stderr)
    if #args == 0 then
        writeRed(process.error(), "sh: missing script file argument\n")
        st().lastExitCode = 1
        return
    end
    st().lastExitCode = runScriptSubshell(args[1], args)
end

builtins["ksh"] = builtins["sh"]

builtins["source"] = function(args, stdin, stdout, stderr)
    if #args == 0 then return end
    sourceFile(args[1], polaris.env.current().getenv)
end
builtins["."] = builtins["source"]

local function utf8_chars(s)
    local i = 0
    return function()
        i = i + 1
        local c = unicode.sub(s, i, i)
        return c ~= "" and c or nil
    end
end

-- Mmmm ring buffers how I like you
local maxHisLen = polaris.config["ksh_history_length"] or 16
local history = { entries = {}, maxLen = maxHisLen }
local eofCount = 0

local function historyMaxLen()
    local v = polaris and polaris.config and polaris.config["ksh_history_length"]
    return (type(v) == "number" and v > 0) and math.floor(v) or maxHisLen
end

local function historyPush(line)
    if line == "" then return end
    local h = history.entries
    if h[#h] == line then return end
    h[#h + 1] = line
    local max = historyMaxLen()
    while #h > max do table.remove(h, 1) end
end

-- I hate OC clipboard handling. Its pure ass. So screw you, no multiline paste for anyone, it will remain broken
-- HORRIBLE readline this is genuinely abysmal but I need something
local function readline()
    local buf = {}
    local pos = 0
    local hIdx = nil
    local liveBuf = {}

    local function displayWidth(s)
        if unicode and unicode.wlen then
            return unicode.wlen(s)
        elseif unicode and unicode.len then
            return unicode.len(s)
        end
        return #s
    end

    local function moveCursorLeft(columns)
        if columns > 0 then
            tty:write_str("\27[" .. columns .. "D")
        end
    end

    local function moveCursorRight(columns)
        if columns > 0 then
            tty:write_str("\27[" .. columns .. "C")
        end
    end

    local function redrawLine()
        local line = table.concat(buf)
        local prompt = st().currPath .. "> "
        local suffix = table.concat(buf, "", pos + 1)
        local suffixW = displayWidth(suffix)
        tty:write_str("\r" .. prompt .. line .. "\27[K")
        moveCursorLeft(suffixW)
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

    local savedOnKeyDown = tty.onKeyDown
    local savedClipboard = tty.clipboard

    tty.rb = ""
    if signalPrompt then
        signalPrompt = false
    else
        drawPrompt()
    end

    local resultLine = nil
    local done = false

    tty.onKeyDown = function(self_tty, char, code)
        if done then return end
        -- Deal with delete
        if char == 127 then
            if pos > 0 then
                table.remove(buf, pos)
                pos = pos - 1
                resetHistoryNavigation()
                redrawLine()
            end

            return
        end

        -- Ok navigation
        if char == 0 then
            if code == 200 then -- Up arrow
                local h = history.entries
                if #h == 0 then return end

                if hIdx == nil then
                    liveBuf = { table.unpack(buf) }
                    hIdx = #h
                else
                    hIdx = math.max(1, hIdx - 1)
                end

                replaceBuffer(h[hIdx])
                redrawLine()
                return
            elseif code == 208 then -- Down arrow
                local h = history.entries
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
                return
            elseif code == 203 then -- left arrow
                if pos > 0 then
                    local ch = buf[pos]
                    pos = pos - 1
                    moveCursorLeft(displayWidth(ch))
                end
                return
            elseif code == 205 then -- right arrow
                if pos < #buf then
                    local ch = buf[pos + 1]
                    pos = pos + 1
                    moveCursorRight(displayWidth(ch))
                end
                return
            elseif code == 211 then -- delete
                if pos < #buf then
                    table.remove(buf, pos + 1)
                    resetHistoryNavigation()
                    redrawLine()
                end
                return
            elseif code == 199 then -- home
                pos = 0
                redrawLine()
                return
            elseif code == 207 then -- end
                pos = #buf
                redrawLine()
                return
            end

            return
        end

        -- enter
        if char == 13 then
            resultLine = table.concat(buf)
            tty:write_str("\n")
            done = true
            return
        end

        -- backspace
        if char == 8 then
            if pos > 0 then
                table.remove(buf, pos)
                pos = pos - 1
                resetHistoryNavigation()
                redrawLine()
            end
            return
        end

        -- CTRL A
        if char == 1 then
            pos = 0
            redrawLine()
            return
        end

        -- CTRL E
        if char == 5 then
            pos = #buf
            redrawLine()
            return
        end

        -- CTRL D
        if char == 4 then
            if #buf == 0 then
                eofCount = eofCount + 1
                resultLine = nil
                tty:write_str("\n")
                done = true
            elseif pos < #buf then
                eofCount = 0
                table.remove(buf, pos + 1)
                resetHistoryNavigation()
                redrawLine()
            end
            return
        end

        eofCount = 0

        if char < 32 and char ~= 9 then
            savedOnKeyDown(self_tty, char, code)
            buf = {}
            pos = 0
            hIdx = nil
            liveBuf = {}
            resultLine = ""
            done = true
            return
        end

        -- Hey look invalid characters cant happen (in theory)
        if char < 0 or char > 0x10FFFF
            or (char >= 0xD800 and char <= 0xDFFF) then
            return
        end

        local ch = (char > 255 and unicode.char or string.char)(char)
        table.insert(buf, pos + 1, ch)
        pos = pos + 1
        resetHistoryNavigation()

        if pos == #buf then
            tty:write_str(ch)
        else
            redrawLine()
        end
    end

    tty.clipboard = function(self_tty, text)
        if done then return end

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
        eofCount = 0

        local lineEnd = nil
        for i, c in ipairs(buf) do
            if c == "\n" then
                lineEnd = i
                break
            end
        end

        if lineEnd then
            resultLine = table.concat(buf, "", 1, lineEnd - 1)
            tty:write_str("\n")
            done = true
            return
        end

        redrawLine()
    end

    while not done do
        coroutine.yield()
    end

    tty.onKeyDown = savedOnKeyDown
    tty.clipboard = savedClipboard
    tty.rb = ""

    if resultLine == nil then return nil end
    historyPush(resultLine)
    return resultLine
end

-- Loop. I hate this.

local function shellLoop()
    local stdin = process.input()
    local env = polaris.env.current()
    -- We know our uid
    shellUid = process.self().uid
    env.setenv("PWD", st().currPath)
    if not env.getenv("PATH") then
        env.setenv("PATH", "/bin:/sbin")
    end

    -- Non-interactive script execution
    local scriptPath = env.args and env.args[1]
    if scriptPath then
        st().scriptArgs = env.args
        runScript(scriptPath, env.getenv)
        return
    end

    tty:clear()
    sourceFile("/etc/.kshrc", env.getenv)

    while true do
        local line = readline()

        if not line then
            tty:write("\n")
            return
        end

        -- I hope nothing comes back
        if process.isSignal(line) then
        else
            env.setenv("PWD", st().currPath)
            executeLine(line, env.getenv)
        end
    end
end

shellPid = process.spawn(shellLoop, {
    cmd = "/bin/ksh.lua",
    label = "ksh",
    gid = process.GID.USER,
    onExit = function(success, reason)
        if polaris.config["debug"] == true then
            computer.beep(2000)
            computer.beep(2000)
            polaris.debug.print(tostring(success) .. " " .. tostring(reason))

            tty:setCursor(false)
            tty:clear()
            tty:detach(shellPid)
            tty:close()
        else
            if tty.attach then
                tty:setCursor(false)
                tty:clear()
                tty:detach(shellPid)
                tty:close()
            end
            process.destroy(shellPid)
        end
    end,
    -- Yay handlers
    handlers = {
        -- INT = function(uid, sig)
        --     drawPrompt()
        -- end,
        HUP = function(uid, sig)
            drawPrompt()
        end,
    },
})

process.create(shellPid, tty.reader, tty, tty)

if tty.attach then
    tty:attach(shellPid)
end
