-- /bin/ksh.lua
-- Okay more stuff ported

local process = polaris.process
polaris.analytics.addEvent("ksh-" .. process.self().uid)
local filesystem = require("filesystem")
local io = polaris.io
local text = require("text")
local unicode = require("unicode")
local termio = require("termio") -- finally because event handlers SUCK
local readline = require("ksh.readline")

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
local function readerPassthrough(reader)
    return {
        read = function(_, ...) return reader:read(...) end,
        readLine = function(_, ...) return reader:readLine(...) end,
        close = function() end,
    }
end

-- Here is a string <<<
local function makeStringReader(content)
    local pos = 1
    local n = #content
    return {
        -- This is incredibly jank but it works lmao. I hope.
        read = function(_, fmt)
            if pos > n then
                return nil
            end
            local want

            if fmt == nil or fmt == math.huge or fmt == "*a" then
                want = n
            elseif fmt == "*l" or fmt == "l" then
                local nl = content:find("\n", pos, true)
                want = nl and (nl - 1) or n
            elseif type(fmt) == "number" then
                want = math.min(pos + fmt - 1, n)
            else
                want = n
            end

            if pos <= want then
                local chunk = content:sub(pos, want)
                pos = want + 1
                return chunk
            end
            return nil
        end,
        readLine = function()
            if pos > n then
                return nil
            end
            local nl = content:find("\n", pos, true)
            local chunk, newpos

            if nl then
                chunk = content:sub(pos, nl - 1)
                newpos = nl + 1
            else
                chunk = content:sub(pos)
                newpos = n + 1
            end

            pos = newpos
            if chunk == "" and pos > n then
                return nil
            end
            return chunk
        end,
        close = function() end,
    }
end

local function writerPassthrough(writer)
    return {
        write = function(_, ...) return writer:write(...) end,
        flush = function(_)
            if writer.flush then return writer:flush() end
            return true
        end,
        close = function() end,
    }
end

local function ttyOutPassthrough()
    return writerPassthrough(tty)
end

local function ttyInPassthrough()
    return readerPassthrough(tty.reader)
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
    fgBusy = false,       -- true while a foreground pipeline is actually going
    gid = process.GID.FG, -- No jobs yet.
    asyncJobs = {},       -- wait
    shellStartTime = computer.uptime(),
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
        local prev = (i > 1) and line:sub(i - 1, i - 1) or " "

        if c == '"' and not inS then
            inD = not inD
        elseif c == "'" and not inD then
            inS = not inS
        elseif c == "(" and not inD and not inS then
            subDepth = subDepth + 1
        elseif c == ")" and not inD and not inS and subDepth > 0 then
            subDepth = subDepth - 1
        elseif c == "#" and not inD and not inS and subDepth == 0
            and (prev == " " or prev == "\t" or prev == ";" or prev == "\n") then
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

-- Math in ((...)) this is absurdly complex but I did all the work in MShell already
local function evaluateArithmetic(expr, getenv)
    local POW = function(a, b) return (tonumber(a) or 0) ^ (tonumber(b) or 0) end
    local XOR = function(a, b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end

    local TERN = function(c, x, y)
        local truth = type(c) == "boolean" and c or ((tonumber(c) or 0) ~= 0)
        if truth then return x end
        return y
    end

    -- Replace vars
    local function varValue(name)
        local v = lookupVar(name, getenv)
        if v == nil or v == "" then return "0" end
        return tostring(v)
    end

    -- Deal with ${var:-word}, ${var:=word}, ${var:+word}, ${var:?word}
    expr = expr:gsub("%$%{([%a_][%w_]*):([%-=+?])([^}]*)%}", function(name, op, arg)
        local val = lookupVar(name, getenv)
        if val ~= nil and val ~= "" then
            if op == "+" then return arg end
            return val
        end

        if op == "-" then return arg end
        if op == "=" then
            st().locals[name] = arg
            return arg
        end

        if op == "?" then
            writeRed(process.error(), "ksh: " .. name .. ": " .. (arg ~= "" and arg or "parameter not set"), "\n")
            return "0"
        end
        return "0"
    end)

    -- And $var and ${var}
    expr = expr:gsub("%$([%a_][%w_]*)", function(name)
        return varValue(name)
    end)
    expr = expr:gsub("%$%{([%a_][%w_]*)%}", function(name)
        return varValue(name)
    end)
    expr = expr:gsub("%$%?", tostring(st().lastExitCode))
    expr = expr:gsub("%$%$", tostring(shellPid or 0))
    expr = expr:gsub("%$([%d]+)", function(num)
        return varValue(num)
    end)
    expr = expr:gsub("%$([#@*0])", function(sym)
        return varValue(sym)
    end)

    local aname, aop, arhs = expr:match("^%s*([%a_][%w_]*)%s*([%+%-*/%%]?)=%s*(.+)$") -- Thank goodness for lua pattern maker!
    if aname and arhs:sub(1, 1) ~= "=" then
        local rhs = math.floor(tonumber(evaluateArithmetic(arhs, getenv)) or 0)
        local cur = math.floor(tonumber(lookupVar(aname, getenv)) or 0)
        local newv = rhs
        if aop == "+" then
            newv = cur + rhs
        elseif aop == "-" then
            newv = cur - rhs
        elseif aop == "*" then
            newv = cur * rhs
        elseif aop == "/" then
            if rhs == 0 then newv = 0 else newv = math.floor(cur / rhs) end
        elseif aop == "%" then
            if rhs == 0 then newv = 0 else newv = cur % rhs end
        end
        st().locals[aname] = tostring(newv)
        return newv
    end

    local pname = expr:match("^%s*([%a_][%w_]*)%+%+%s*$")
    local dname = expr:match("^%s*([%a_][%w_]*)%-%-%s*$")
    if pname or dname then
        local nm = pname or dname
        local cur = math.floor(tonumber(lookupVar(nm, getenv)) or 0)
        st().locals[nm] = tostring(cur + (pname and 1 or -1))
        return cur
    end

    pname = expr:match("^%s*%+%+([%a_][%w_]*)%s*$")
    dname = expr:match("^%s*%-%-([%a_][%w_]*)%s*$")
    if pname or dname then
        local nm = pname or dname
        local cur = math.floor(tonumber(lookupVar(nm, getenv)) or 0) + (pname and 1 or -1)
        st().locals[nm] = tostring(cur)
        return cur
    end

    expr = expr:gsub("[%a_][%w_]*", function(id)
        if id == "nil" or id == "true" or id == "false" then return id end
        local v = lookupVar(id, getenv)
        if v == nil or v == "" then return "0" end
        return tostring(v)
    end)

    expr = expr:gsub("!=", "~=")
    expr = expr:gsub("([%w_.]+)%*%*([%w_.]+)", "POW(%1,%2)")
    expr = expr:gsub("([%w_.]+)%^([%w_.]+)", "XOR(%1,%2)")

    -- Who even uses this? I guess me
    local function translateTernary(e)
        local depth, qpos = 0, nil

        for i = 1, #e do
            local c = e:sub(i, i)
            if c == "(" then
                depth = depth + 1
            elseif c == ")" then
                depth = depth - 1
            elseif c == "?" and depth == 0 then
                qpos = i
                break
            end
        end
        if not qpos then return e end
        local cond = translateTernary(e:sub(1, qpos - 1))
        depth = 0
        local ternDepth, colon = 0, nil

        for i = qpos + 1, #e do
            local c = e:sub(i, i)
            if c == "(" then
                depth = depth + 1
            elseif c == ")" then
                depth = depth - 1
            elseif c == "?" and depth == 0 then
                ternDepth = ternDepth + 1
            elseif c == ":" then
                if depth == 0 then
                    if ternDepth == 0 then
                        colon = i
                        break
                    end
                    ternDepth = ternDepth - 1
                end
            end
        end
        if not colon then return e end
        return "TERN(" .. cond .. "," ..
            translateTernary(e:sub(qpos + 1, colon - 1)) .. "," ..
            translateTernary(e:sub(colon + 1)) .. ")"
    end
    expr = translateTernary(expr)

    -- Kindly dont crash my shell though. MShell sure got that wrong...
    local fn, err = load("return " .. expr, "=arithmetic", "t",
        { math = math, POW = POW, XOR = XOR, TERN = TERN })
    if not fn then
        writeRed(process.error(), "ksh: arithmetic error: " .. tostring(err), "\n")
        return 0
    end

    local ok, result = pcall(fn)
    if not ok then
        writeRed(process.error(), "ksh: arithmetic error: " .. tostring(result), "\n")
        return 0
    end
    if result == true then return 1 end
    if result == false then return 0 end
    return math.floor(tonumber(result) or 0)
end

-- Gross.
local function expandCommandSubstitutions(str, getenv)
    local out = {}
    local lastStatus
    local i, n = 1, #str

    local function findMatchingParen(s, start)
        local depth = 0
        local frames = {}
        local prevDollar = false
        local j = start
        while j <= #s do
            local c = s:sub(j, j)
            local top = frames[#frames]
            local qhere = (top and top.lvl == depth) and top.q or nil
            if c == "(" then
                if not qhere or (prevDollar and qhere ~= "'") then
                    depth = depth + 1
                end
                prevDollar = false
            elseif c == ")" then
                if not qhere and depth > 0 then
                    depth = depth - 1
                    if depth == 0 then return j end
                end
                prevDollar = false
            else
                if qhere and qhere == c then
                    table.remove(frames)
                elseif c == "'" or c == '"' or c == "`" then
                    table.insert(frames, { q = c, lvl = depth })
                end
                prevDollar = (c == "$")
            end
            j = j + 1
        end
        return nil
    end

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
            if str:sub(nxt + 1, nxt + 2) == "((" then
                -- $((...))
                local close = findMatchingParen(str, nxt + 2)
                if not close then
                    writeRed(process.error(), "ksh: missing )) to match ((", "\n")
                    return table.concat(out), lastStatus
                end

                local expr = str:sub(nxt + 3, close - 1)
                local result = evaluateArithmetic(expr, getenv)
                out[#out + 1] = tostring(result)
                i = close + 1
                if i <= n and str:sub(i, i) == ")" then
                    i = i + 1
                end
            elseif str:sub(nxt + 1, nxt + 1) == "(" then
                -- Command substi $(...)
                local close = findMatchingParen(str, nxt + 1)
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
            arg = expandVars(arg, getenv)
            local result, err = applyOperator(name, op, arg, lookupVar(name, getenv))
            if err then failMsg = failMsg or err end
            return result or ""
        end

        local iname = body:match("^!(.+)$")
        if iname then
            local ref = lookupVar(iname, getenv)
            return lookupVar(ref or "", getenv) or ""
        end

        -- Why must escaped env variables exist? Like wtf is this pattern I made 5 years ago dude
        local sname, soff, slen = body:match("^([%a_][%w_]*):(%-?%d+):?(%-?%d*)$")
        if sname then
            local val = tostring(lookupVar(sname, getenv) or "")
            local start = tonumber(soff)
            if start < 0 then
                start = math.max(#val + start, 0)
            end
            if slen ~= "" then
                local len = tonumber(slen)
                if len < 0 then
                    return val:sub(start + 1, math.max(#val + len, start))
                end
                return val:sub(start + 1, start + len)
            end
            return val:sub(start + 1)
        end

        local rname, sep, rest = body:match("^([%a_][%w_]*)(/+)(.*)$")
        if rname then
            local val = tostring(lookupVar(rname, getenv) or "")
            local pat, rep = rest:match("^([^/]*)/(.*)$")
            pat = pat or ""
            rep = rep or ""
            local luaPat = ""

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
            if sep == "//" then
                return (val:gsub(luaPat, function() return rep end))
            end
            local s, e = val:find(luaPat)
            if s then
                return val:sub(1, s - 1) .. rep .. val:sub(e + 1)
            end
            return val
        end

        local prefixName, prefixOp, prefPat = body:match("^([%a_][%w_]*)(##?)(.+)$")
        if prefixName then
            local val = tostring(lookupVar(prefixName, getenv) or "")
            local luaPat = ""
            for idx = 1, #prefPat do
                local c = prefPat:sub(idx, idx)
                if c == "*" then
                    luaPat = luaPat .. (prefixOp == "##" and ".*" or ".-")
                elseif c == "?" then
                    luaPat = luaPat .. "."
                elseif c:match("%W") then
                    luaPat = luaPat .. "%" .. c
                else
                    luaPat = luaPat .. c
                end
            end
            local s, e = val:find("^" .. luaPat)
            if s then
                return val:sub(e + 1)
            end
            return val
        end

        local suffixName, suffixOp, sufPat = body:match("^([%a_][%w_]*)(%%?%%)(.+)$")
        if suffixName then
            local val = tostring(lookupVar(suffixName, getenv) or "")
            local luaPat = ""
            for idx = 1, #sufPat do
                local c = sufPat:sub(idx, idx)
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
            local j = (suffixOp == "%%") and 1 or #val
            local step = (suffixOp == "%%") and 1 or -1
            while j >= 1 and j <= #val do
                if val:sub(j):match("^" .. luaPat .. "$") then
                    return val:sub(1, j - 1)
                end
                j = j + step
            end
            return val
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
local function protectEscapedDollar(str)
    return str:gsub("\\%$", "\000ESCAPED_DOLLAR\000")
end

local function restoreEscapedDollar(str)
    return str:gsub("%zESCAPED_DOLLAR%z", "$")
end

-- Fine il do it again...
local function expandToken(w, getenv)
    local quotes = {
        { "'", "'" },
        { '"', '"' }
    }
    local segs = {}
    local cur = { kind = "raw", txt = "" }
    local frames = {}
    local depth = 0
    local prevDollar = false

    local function flush()
        if #cur.txt > 0 or cur.kind ~= "raw" then
            segs[#segs + 1] = cur
        end
        cur = { kind = "raw", txt = "" }
    end

    -- please dont crash please dont crash
    for i = 1, #w do
        local char = w:sub(i, i)
        local top = frames[#frames]
        local qhere = (top and top.lvl == depth) and top.q or nil

        if char == "(" then
            if not qhere or (prevDollar and qhere ~= "'") then
                depth = depth + 1
            end
            cur.txt = cur.txt .. char
            prevDollar = false
        elseif char == ")" then
            if not qhere and depth > 0 then
                depth = depth - 1
            end
            cur.txt = cur.txt .. char
            prevDollar = false
        elseif qhere and qhere == char then
            table.remove(frames)
            if #frames > 0 then
                cur.txt = cur.txt .. char
            else
                flush()
            end
            prevDollar = false
        elseif qhere then
            cur.txt = cur.txt .. char
            prevDollar = (char == "$")
        else
            local rec
            for _, Q in ipairs(quotes) do
                if Q[1] == char then rec = Q end
            end

            if rec then
                if top then
                    cur.txt = cur.txt .. char
                else
                    flush()
                    cur = { kind = rec[1], txt = "" }
                end
                table.insert(frames, { q = rec[1], lvl = depth })
            else
                cur.txt = cur.txt .. char
            end

            prevDollar = false
        end
    end
    flush()

    local result = ""
    local failMsg, subStatus
    for _, seg in ipairs(segs) do
        if seg.kind == "'" then
            result = result .. seg.txt
        elseif seg.kind == '"' then
            local inner = protectEscapedDollar(seg.txt)
            inner = inner:gsub("\\([`\"\\])", "%1")
            local expanded, failMsg2, subStatus2 = expandVars(inner, getenv)
            failMsg = failMsg or failMsg2
            subStatus = subStatus or subStatus2
            result = result .. restoreEscapedDollar(expanded)
        else
            local inner = protectEscapedDollar(seg.txt)
            local expanded, failMsg2, subStatus2 = expandVars(inner, getenv)
            failMsg = failMsg or failMsg2
            subStatus = subStatus or subStatus2
            expanded = restoreEscapedDollar(expanded)
            if expanded == "~" or expanded:sub(1, 2) == "~/" then
                local home = getenv("HOME") or "/"
                expanded = home .. expanded:sub(2)
            end
            result = result .. expanded
        end
    end
    return result, failMsg, subStatus
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
local function expandBraceToken(str)
    local function splitTopCommas(body)
        local depth = 0
        local parts = { "" }
        local i = 1

        while i <= #body do
            local c = body:sub(i, i)
            if c == "{" then
                depth = depth + 1
                parts[#parts] = parts[#parts] .. c
            elseif c == "}" then
                if depth > 0 then depth = depth - 1 end
                parts[#parts] = parts[#parts] .. c
            elseif c == "," and depth == 0 then
                parts[#parts + 1] = ""
            else
                parts[#parts] = parts[#parts] .. c
            end
            i = i + 1
        end
        if #parts > 1 then
            return parts
        end
        return nil
    end

    -- I think I got this right. I refuse to use my own bit32 library haha
    local function rangeItems(ra, rb)
        local na, nb = tonumber(ra), tonumber(rb)
        if na and nb then
            local width = 0
            if ra:sub(1, 1) == "0" or rb:sub(1, 1) == "0" then
                width = math.max(#ra, #rb)
            end
            local fmt = ("%0" .. width .. "d")
            local items = {}
            local step = (na <= nb) and 1 or -1
            local v = na

            while true do
                items[#items + 1] = string.format(fmt, v)
                if v == nb then break end
                v = v + step
            end
            return items
        end
        if #ra == 1 and #rb == 1 then
            local ca, cb = ra:byte(), rb:byte()
            local cOk = (ca >= 65 and ca <= 90) or (ca >= 97 and ca <= 122)
            local cCb = (cb >= 65 and cb <= 90) or (cb >= 97 and cb <= 122)
            if cOk and cCb then
                local items = {}
                local step = (ca <= cb) and 1 or -1
                local v = ca
                while true do
                    items[#items + 1] = string.char(v)
                    if v == cb then break end
                    v = v + step
                end
                return items
            end
        end
        return nil
    end

    -- Easy
    local function expandOne(s)
        local i = 1
        while i <= #s do
            if s:sub(i, i) == "{" then
                local depth = 1
                local j = i + 1
                local found = nil

                while j <= #s and depth > 0 do
                    local cj = s:sub(j, j)
                    if cj == "{" then
                        depth = depth + 1
                    elseif cj == "}" then
                        depth = depth - 1
                        if depth == 0 then found = j end
                    end
                    j = j + 1
                end

                if found then
                    local body = s:sub(i + 1, found - 1)
                    local expandedBodies = nil
                    local parts = splitTopCommas(body)

                    if parts then
                        expandedBodies = parts
                    else
                        local ra, rb = body:match("^([^,]+)%.%.([^,]+)$")
                        if ra and rb then
                            expandedBodies = rangeItems(ra, rb)
                        end
                    end

                    if expandedBodies then
                        local out = {}
                        local prefix = s:sub(1, i - 1)
                        local suffix = s:sub(found + 1)
                        for _, eb in ipairs(expandedBodies) do
                            local cand = prefix .. eb .. suffix
                            for _, e2 in ipairs(expandOne(cand)) do
                                out[#out + 1] = e2
                            end
                        end
                        return out
                    end
                end
            end
            i = i + 1 -- this looks aweful. end end end end end
        end
        return { s }
    end

    return expandOne(str)
end

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
    local braceGroup

    local function dealWithToken(w)
        local isQuoted = (#w >= 2) and
            ((w:sub(1, 1) == '"' and w:sub(-1) == '"') or (w:sub(1, 1) == "'" and w:sub(-1) == "'"))
        local expanded, failMsg, subStatus = expandToken(w, getenv)
        expandFail = expandFail or failMsg
        if isQuoted then return { expanded } end
        local braceParts = expandBraceToken(expanded)
        local out = {}

        for _, part in ipairs(braceParts) do
            if subStatus ~= nil then
                for field in part:gmatch("%S+") do
                    for _, m in ipairs(expandWildcard(field)) do
                        out[#out + 1] = m
                    end
                end
            else
                for _, m in ipairs(expandWildcard(part)) do
                    out[#out + 1] = m
                end
            end
        end
        return out
    end

    -- (thing) and { list; }
    if type(words[1]) == "table" and words[1].subshell then
        subshell = words[1].subshell
        i = 2
    elseif type(words[1]) == "table" and words[1].braceGroup then
        braceGroup = words[1].braceGroup
        i = 2
    end

    while i <= #words do
        local w = words[i]
        if type(w) == "table" then
            if w.braceGroup then
                return nil, "unexpected syntax after { list }"
            end
            return nil, "syntax error near '('"
        elseif w == "<" then
            if type(words[i + 1]) ~= "string" then return nil, "missing filename after <" end
            redirects.stdinFile = dealWithToken(words[i + 1])[1]
            i = i + 2
        elseif w == "<<<" then -- I forgot completely about this guy
            local nxt = words[i + 1]
            if type(nxt) ~= "string" or nxt == "<" or nxt == ">" or nxt == ">>"
                or nxt == ";"
                or nxt == "|" or nxt == "&&" or nxt == "||" then
                return nil, "syntax error near '<<<'"
            end
            local fields = dealWithToken(nxt)
            redirects.stdinString = table.concat(fields, " ") .. "\n"
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
                if braceGroup then
                    return nil, "unexpected word after { list }"
                end
                local expandedList = dealWithToken(w)
                for _, item in ipairs(expandedList) do
                    args[#args + 1] = item
                end
                i = i + 1
            end
        end
    end

    if #args == 0 and not subshell and not braceGroup then
        return nil, "empty command"
    end

    if expandFail then
        return nil, expandFail, true
    end

    if subshell then
        return { subshell = subshell, redirects = redirects }
    end

    if braceGroup then
        return { braceGroup = braceGroup, redirects = redirects }
    end

    return { args = args, redirects = redirects }
end

local builtins = {}
local reservedKeywords = {
    time = true,
    -- better shell scripting soon(tm)
}

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
    return io.open(full, append and "a" or "w")
end

-- error reason: path
local function ioErr(reason, path)
    return tostring(reason) .. ": " .. path
end

-- Where should they go?
local function ownStdin()
    local shellIO = st().io
    if shellIO and shellIO.stdin then
        return readerPassthrough(shellIO.stdin)
    end
    if inSubshell() then
        return readerPassthrough(process.input())
    end
    return ttyInPassthrough()
end

local function ownStdout()
    local shellIO = st().io
    if shellIO and shellIO.stdout then
        return writerPassthrough(shellIO.stdout)
    end
    if inSubshell() then
        return writerPassthrough(process.output())
    end
    return ttyOutPassthrough()
end

local function ownStderr()
    local shellIO = st().io
    if shellIO and shellIO.stderr then
        return writerPassthrough(shellIO.stderr)
    end
    if inSubshell() then
        return writerPassthrough(process.error())
    end
    return ttyOutPassthrough()
end

local function closeStreams(streams)
    if not streams then return end
    local seen = {}
    for _, stream in ipairs(streams) do
        if not seen[stream] then
            seen[stream] = true
            pcall(function()
                if stream.close then stream:close() end
            end)
        end
    end
end

-- Decides fd0/1/2 or tty
local function makeStreams(inPipe, outPipe, redirects)
    local stdin, stdout, stderr
    local owned = {}

    local function fail(err)
        closeStreams(owned)
        return nil, nil, nil, err
    end

    if redirects.stdinFile then
        local full = resolvePath(st().currPath, redirects.stdinFile)
        if not filesystem.exists(full) then
            return fail(ioErr("no such file or directory", redirects.stdinFile))
        end
        if filesystem.isDirectory(full) then
            return fail(ioErr("is a directory", redirects.stdinFile))
        end
        local stream, reason = io.open(full, "r")
        if not stream then return fail(ioErr(reason, redirects.stdinFile)) end
        stdin = stream
        owned[#owned + 1] = stream
    elseif redirects.stdinString then
        stdin = makeStringReader(redirects.stdinString)
        owned[#owned + 1] = stdin
    else
        stdin = inPipe or ownStdin()
    end

    if redirects.stdoutFile then
        local full = resolvePath(st().currPath, redirects.stdoutFile)
        if filesystem.isDirectory(full) then
            return fail(ioErr("is a directory", redirects.stdoutFile))
        end
        local stream, reason = openForOutput(full, redirects.appendOut)
        if not stream then return fail(ioErr(reason, redirects.stdoutFile)) end
        stdout = stream
        owned[#owned + 1] = stream
    else
        stdout = outPipe or ownStdout()
    end

    if redirects.stderrFile then
        local full = resolvePath(st().currPath, redirects.stderrFile)
        if filesystem.isDirectory(full) then
            return fail(ioErr("is a directory", redirects.stderrFile))
        end
        local stream, reason = openForOutput(full, redirects.appendStderr)
        if not stream then return fail(ioErr(reason, redirects.stderrFile)) end
        stderr = stream
        owned[#owned + 1] = stream
    else
        stderr = ownStderr()
    end

    -- Yay fd aliasing
    if redirects.fdAliases then
        local resolved = { [0] = stdin, [1] = stdout, [2] = stderr }
        for dst, src in pairs(redirects.fdAliases) do
            local stream = resolved[src]
            if not stream then
                return fail("bad file descriptor: &" .. src)
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

    return stdin, stdout, stderr, nil, owned
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
        pathStr = "/usr/bin:/bin:/sbin"
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
        pipes[i] = io.newPipe(polaris.scheduler, 2048)
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

    local function spawnSegment(segIdx)
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
                        env.ctty =
                            tty -- current tty, I am too lazy to deal with /dev/tty* bs and this is far easier for me
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

                            -- this works now magically. mmmmkay
                            open = function(...) return io.open(...) end,

                            -- Hey look, actual stream objects
                            stdin = fdStream(0),
                            stdout = fdStream(1),
                            stderr = fdStream(2),
                        }

                        local ok, err = xpcall(function()
                            if builtin then
                                return builtin(argv(seg.args), process.input(), {
                                    write = function(_, ...) return process.write(...) end,
                                    flush = function() return process.output():flush() end,
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

    for segIdx = 1, segCount do
        if not parsedSegments[segIdx].braceGroup then
            spawnSegment(segIdx)
        end
    end

    for segIdx = 1, segCount do
        local seg = parsedSegments[segIdx]
        if seg.braceGroup then
            local inPipe = pipes[segIdx - 1]
            local outPipe = pipes[segIdx]
            local stdin, stdout, stderr, err, owned = makeStreams(inPipe, outPipe, seg.redirects)

            if err then
                writeRed(process.error(), "ksh: " .. err, "\n")
                segmentDone(segIdx, 1, inPipe, outPipe)
            else
                -- Oh boy. I/o
                local savedIO = st().io
                st().io = { stdin = stdin, stdout = stdout, stderr = stderr }

                local ok, groupErr = xpcall(function()
                    executeTokens(seg.braceGroup, getenv)
                end, debug.traceback)

                st().io = savedIO

                if not ok then
                    writeRed(process.error(), tostring(groupErr), "\n")
                    st().lastExitCode = 1
                end

                pcall(function()
                    if stdout.flush then stdout:flush() end
                    if stderr.flush then stderr:flush() end
                end)

                closeStreams(owned)
                segmentDone(segIdx, st().lastExitCode, inPipe, outPipe)
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

-- Metatable trick to save memory
local function snapshotState(gid)
    local s = st()
    local copy = {
        locals = setmetatable({}, { __index = s.locals }),
        scriptArgs = s.scriptArgs,
        aliases = setmetatable({}, { __index = s.aliases }),
        currPath = s.currPath,
        lastExitCode = s.lastExitCode,
        fgBusy = false,
        gid = gid or s.gid,
        asyncJobs = {},
        shellStartTime = s.shellStartTime,
    }
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
    local pipe = io.newPipe(polaris.scheduler, 2048)
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
        if reservedKeywords[name] then
            stdout:write(name .. " is a reserved keyword\n")
        elseif st().aliases[name] then
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

-- which? winch? witch
builtins["which"] = function(args, stdin, stdout, stderr)
    if #args == 0 then
        stderr:write("ksh: which: no command specified\n")
        st().lastExitCode = 1
        return
    end

    local env = polaris.env.current()
    local hasError = false
    for _, name in ipairs(args) do
        local cmdPath = resolveCommand(name, env.getenv)
        if cmdPath then
            stdout:write(cmdPath .. "\n")
        else
            stderr:write("ksh: which: " .. name .. ": not found\n")
            hasError = true
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

local function formatTime(seconds)
    local m = math.floor(seconds / 60)
    local s = seconds - m * 60
    return string.format("%dm%.3fs", m, s)
end

-- Yes, this is seperate. Im lazy
local function runTimedCommandGroup(rest, assigns, saved, savedNames, getenv)
    local function restoreLocals()
        if not savedNames then return end
        for _, name in ipairs(savedNames) do
            st().locals[name] = saved[name]
        end
    end

    local pipeGroups = splitTokensOn(rest, "|")
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

-- Everything but && and ;
local function runCommandGroup(words, getenv)
    local assigns, rest = splitAssignments(words)

    if #assigns > 0 and #rest == 0 then
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

    local hasTime = false
    if #rest > 0 and rest[1] == "time" then
        hasTime = true
        table.remove(rest, 1)
    end

    if hasTime then
        if #rest == 0 then
            local shellStart = st().shellStartTime or computer.uptime()
            local shellEnd = computer.uptime()
            local realTime = shellEnd - shellStart

            local stderr = ownStderr()
            stderr:write("real\t", formatTime(realTime), "\n")
            if stderr.flush then stderr:flush() end
            st().lastExitCode = 0
            return
        end

        local realStart = computer.uptime()
        local cpuStart = os.clock()

        runTimedCommandGroup(rest, assigns, saved, savedNames, getenv)

        local realEnd = computer.uptime()
        local cpuEnd = os.clock()

        local realTime = realEnd - realStart
        local sysTime = cpuEnd - cpuStart

        local stderr = ownStderr()
        stderr:write("real\t", formatTime(realTime), "\n")
        stderr:write("sys\t", formatTime(sysTime), "\n")
        if stderr.flush then stderr:flush() end
        return
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
-- Turns out I got it wrong in mshell so il redo it here
local function extractSubshells(tokens)
    local function parseGroup(tokens, i, n, isSubshell, isArithmetic)
        local inner = {}
        local depth = 1
        local j = i

        while j <= n do
            local t = tokens[j]
            if type(t) == "string" and not tokenIsQuoted(t) then
                if t == "(" or t == "$(" or t == "$((" then
                    depth = depth + 1
                    inner[#inner + 1] = t
                elseif t == ")" then
                    depth = depth - 1
                    if depth == 0 then break end
                    inner[#inner + 1] = t
                else
                    inner[#inner + 1] = t
                end
            else
                inner[#inner + 1] = t
            end
            j = j + 1
        end
        if depth ~= 0 then
            return nil, "missing )", j
        end
        if isSubshell then
            if #inner == 0 then
                return nil, "syntax error: empty ( list )", j
            end
            return { subshell = inner }, nil, j + 1
        elseif isArithmetic then
            -- $((...))
            local processed, err = extractSubshells(inner)
            if not processed then return nil, err, j end
            return "$((" .. table.concat(processed, " ") .. "))", nil, j + 1
        else
            -- $(...)
            local processed, err = extractSubshells(inner)
            if not processed then return nil, err, j end
            return "$(" .. table.concat(processed, " ") .. ")", nil, j + 1
        end
    end

    local out = {}
    local i = 1
    local n = #tokens
    while i <= n do
        local tok = tokens[i]
        if type(tok) == "string" and not tokenIsQuoted(tok) then
            if tok == "(" or tok == "$(" or tok == "$((" then
                local isGroup = (tok == "(")
                local isArithmetic = (tok == "$((")
                local result, err, nextI = parseGroup(tokens, i + 1, n, isGroup, isArithmetic)
                if not result then return nil, err end
                out[#out + 1] = result
                i = nextI
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
    -- Now we have ||
    local orGroups = splitTokensOn(tokens, "||")
    for oi, orGroup in ipairs(orGroups) do
        if #orGroup == 0 then
            writeRed(process.error(), "ksh: syntax error near '||'", "\n")
            st().lastExitCode = 2
            return
        end

        local andGroups = splitTokensOn(orGroup, "&&")
        local andResult = true
        for _, andGroup in ipairs(andGroups) do
            if #andGroup == 0 then
                writeRed(process.error(), "ksh: syntax error near '&&'", "\n")
                st().lastExitCode = 2
                return
            end
            runCommandGroup(andGroup, getenv)
            if st().lastExitCode ~= 0 then
                andResult = false
                break
            end
        end
        if andResult then
            return
        end
        -- keep going
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

    tokens, err = text.internal.braceGroups(tokens)
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
    local f, reason = io.open(full, "r")
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
    local f, reason = io.open(full, "r")
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

-- This is so much easier. Readline stuff below
local termioSession = termio.open({ kind = "tty", tty = tty })
local lineEditor = readline.new(termioSession, {
    prompt = function() return st().currPath .. "> " end,
})

-- Loop. I hate this.

local function shellLoop()
    local stdin = process.input()
    local env = polaris.env.current()
    -- We know our uid
    shellUid = process.self().uid
    env.setenv("PWD", st().currPath)
    if not env.getenv("PATH") then
        env.setenv("PATH", "/usr/bin:/bin:/sbin")
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
        -- We kinda need input to always work back in the shell, so we can hopefully fix problems
        tty.attributes["xoff"] = false

        -- Fix doubledraw?
        local promptDrawn = signalPrompt
        signalPrompt = false

        local line = lineEditor:read(promptDrawn)

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
