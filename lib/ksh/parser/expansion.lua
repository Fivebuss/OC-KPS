-- /lib/ksh/parser/expansion.lua
-- This is a big one!
-- I just copied it outside to save ram. And easier to read? Hopefully?
local ctx

-- I cheat here so I dont expand badly. Who cares, you wont see it anyway (hopefully)
local function zoneMark(s, quoted)
    if quoted or #s == 0 then
        return s
    end
    return "\002" .. s .. "\003"
end

-- Deal with the markers
local function unwrapAll(s)
    s = s:gsub("\006(.)\007", "%1")
    return (s:gsub("[\001\002\003\004\005\006\007]", ""))
end

local function applyOperator(name, op, arg, value, colon)
    local isset = value ~= nil and (not colon or value ~= "")
    if isset then
        if op == "+" then return arg end
        return value
    end

    if op == "-" then return arg end
    if op == "=" then
        if ctx.st().readonlys[name] then
            -- Reported by the segment layer, dont double print here
            return nil, name .. ": readonly variable"
        end
        arg = unwrapAll(arg)
        ctx.st().locals[name] = arg
        return arg
    end
    if op == "?" then
        local msg = arg ~= "" and arg or "parameter not set"
        return nil, name .. ": " .. msg
    end
    return "" -- :+ with unset value
end

local function expandCommandSubstitutions(str, getenv, quoted)
    local writeRed = ctx.writeRed
    local runCapture = ctx.capture
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
            out[#out + 1] = zoneMark(text, quoted)
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
                local arith = require("ksh.parser.arithmetic")
                arith.init(ctx)
                local result = arith.eval(expr, getenv)
                out[#out + 1] = zoneMark(tostring(result), quoted)
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
                out[#out + 1] = zoneMark(text, quoted)
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

local function expandVars(str, getenv, quoted)
    local st = ctx.st
    local lookupVar = ctx.lookupVar
    local failMsg
    local subStatus
    -- subs go first!
    str, subStatus = expandCommandSubstitutions(str, getenv, quoted)
    local out = str:gsub("%$%b{}", function(tok)
        local body = tok:sub(3, -2)

        -- expansions used as another shell variable. Yes this happens
        if #body >= 2 and body:sub(1, 1) == "#" then
            local nm = body:sub(2)
            if nm:match("^[%a_][%w_]*$") or nm:match("^%d+$") or nm == "@" or nm == "*" then
                if nm == "@" or nm == "*" then
                    if st().scriptArgs then
                        return zoneMark(tostring(math.max(0, #st().scriptArgs - 1)), quoted)
                    end
                    return zoneMark("0", quoted)
                end
                local v = tostring(lookupVar(nm, getenv) or "")
                return zoneMark(tostring(#v), quoted)
            end
        end

        local name, op, arg = body:match("^([%a_][%w_]*):([%-=+?])(.*)$")
        local colon = not not name
        if not name then
            name, op, arg = body:match("^([%a_][%w_]*)([%-=+?])(.+)$")
        end

        if name then
            -- Little cheat
            local value = lookupVar(name, getenv)
            local isset = value ~= nil and (not colon or value ~= "")
            local useArg
            if op == "+" then
                useArg = isset
            else
                useArg = not isset
            end

            if not useArg then
                if op == "+" then return "" end
                return zoneMark(value, quoted)
            end

            arg = expandVars(arg, getenv, quoted)
            local result, err = applyOperator(name, op, arg, value, colon)
            if err then failMsg = failMsg or err end
            return zoneMark(result or "", quoted)
        end

        local iname = body:match("^!(.+)$")
        if iname then
            local ref = lookupVar(iname, getenv)
            return zoneMark(lookupVar(ref or "", getenv) or "", quoted)
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
                    return zoneMark(val:sub(start + 1, math.max(#val + len, start)), quoted)
                end
                return zoneMark(val:sub(start + 1, start + len), quoted)
            end
            return zoneMark(val:sub(start + 1), quoted)
        end

        -- Fixes weirdness with escaped things. Again
        local rname = body:match("^([%a_][%w_]*)/+")
        if rname then
            local val = tostring(lookupVar(rname, getenv) or "")
            local afterName = body:sub(#rname + 1)
            local sepEnd = 1
            while afterName:sub(sepEnd, sepEnd) == "/" do
                sepEnd = sepEnd + 1
            end

            local global = (sepEnd - 1) >= 2
            local rest = afterName:sub(sepEnd)
            local patChars, wasEsc = {}, {}
            local esc = false
            local cut = nil

            for k = 1, #rest do
                local c = rest:sub(k, k)
                if esc then
                    esc = false
                    local idx = #patChars + 1
                    patChars[idx] = c
                    wasEsc[idx] = true
                elseif c == "\\" then
                    esc = true
                elseif c == "/" then
                    cut = k
                    break
                else
                    local idx = #patChars + 1
                    patChars[idx] = c
                    wasEsc[idx] = false
                end
            end

            local pat = table.concat(patChars)
            local rep = cut and rest:sub(cut + 1) or ""
            if pat == "" then
                return zoneMark(val, quoted)
            end

            local luaPat = ""
            for idx = 1, #pat do
                local c = pat:sub(idx, idx)
                if wasEsc[idx] then
                    if c:match("%W") then
                        luaPat = luaPat .. "%" .. c
                    else
                        luaPat = luaPat .. c
                    end
                elseif c == "*" then
                    luaPat = luaPat .. ".*"
                elseif c == "?" then
                    luaPat = luaPat .. "."
                elseif c:match("%W") then
                    luaPat = luaPat .. "%" .. c
                else
                    luaPat = luaPat .. c
                end
            end

            rep = (rep:gsub("\\(.)", "%1"))
            if global then
                return zoneMark((val:gsub(luaPat, function() return rep end)), quoted)
            end
            local s, e = val:find(luaPat)
            if s then
                return zoneMark(val:sub(1, s - 1) .. rep .. val:sub(e + 1), quoted)
            end
            return zoneMark(val, quoted)
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
                return zoneMark(val:sub(e + 1), quoted)
            end
            return zoneMark(val, quoted)
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
                    return zoneMark(val:sub(1, j - 1), quoted)
                end
                j = j + step
            end
            return zoneMark(val, quoted)
        end

        if body == "?" then return zoneMark(tostring(st().lastExitCode), quoted) end
        if body == "$" then return zoneMark(tostring(ctx.getShellPid() or 0), quoted) end
        return zoneMark(lookupVar(body, getenv) or "", quoted)
    end)

    out = out:gsub("%$%?", function() return zoneMark(tostring(st().lastExitCode), quoted) end)
    out = out:gsub("%$%$", function() return zoneMark(tostring(ctx.getShellPid() or 0), quoted) end)
    out = out:gsub("%$([%d]+)", function(num)
        return zoneMark(lookupVar(num, getenv) or "", quoted)
    end)
    out = out:gsub("%$([#@*0])", function(sym)
        return zoneMark(lookupVar(sym, getenv) or "", quoted)
    end)
    out = out:gsub("%$([%a_][%w_]*)", function(name)
        return zoneMark(lookupVar(name, getenv) or "", quoted)
    end)
    return out, failMsg, subStatus
end

return {
    init = function(c) ctx = c end,
    expandVars = expandVars,
}
