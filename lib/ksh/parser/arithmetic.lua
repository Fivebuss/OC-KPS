-- /lib/ksh/parser/arithmetic.lua
-- I just copied it outside to save ram. And easier to read? Hopefully?
local ctx

local function evaluateArithmetic(expr, getenv)
    local st = ctx.st
    local lookupVar = ctx.lookupVar
    local writeRed = ctx.writeRed
    local wasReadonly = ctx.wasReadonly
    local POW = function(a, b) return (tonumber(a) or 0) ^ (tonumber(b) or 0) end
    local XOR = function(a, b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end

    local TERN = function(c, fx, fy)
        local truth = type(c) == "boolean" and c or ((tonumber(c) or 0) ~= 0)
        if truth then return fx() end
        return fy()
    end

    local TB = function(v)
        if type(v) == "boolean" then return v end
        return (tonumber(v) or 0) ~= 0
    end

    local TN = function(v)
        if v == true then return 1 end
        if v == false then return 0 end
        return tonumber(v) or 0
    end

    -- why bash must be like this
    local DIV = function(a, b)
        a = math.floor(tonumber(a) or 0)
        b = math.floor(tonumber(b) or 0)
        if b == 0 then error("division by 0", 0) end
        local q = a / b
        if q >= 0 then return math.floor(q) end

        return math.ceil(q)
    end
    local MOD = function(a, b)
        a = math.floor(tonumber(a) or 0)
        b = math.floor(tonumber(b) or 0)
        if b == 0 then error("division by 0", 0) end

        return a - DIV(a, b) * b
    end

    local function splitTopLevel(e, op)
        local n, depth, i = #e, 0, 1
        local parts, buf = {}, {}

        while i <= n do
            local c = e:sub(i, i)
            if c == "(" then
                depth = depth + 1
                buf[#buf + 1] = c
                i = i + 1
            elseif c == ")" then
                depth = depth - 1
                buf[#buf + 1] = c
                i = i + 1
            elseif depth == 0 and e:sub(i, i + #op - 1) == op then
                parts[#parts + 1] = table.concat(buf)
                buf = {}
                i = i + #op
            else
                buf[#buf + 1] = c
                i = i + 1
            end
        end
        parts[#parts + 1] = table.concat(buf)

        if #parts == 1 then return nil end
        return parts
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
            if st().readonlys[name] then
                wasReadonly(name)
                return "0"
            end

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
    expr = expr:gsub("%$%$", tostring(ctx.getShellPid() or 0))
    expr = expr:gsub("%$([%d]+)", function(num)
        return varValue(num)
    end)
    expr = expr:gsub("%$([#@*0])", function(sym)
        return varValue(sym)
    end)

    -- screw it lets go left to right
    local commaParts = splitTopLevel(expr, ",")
    if commaParts then
        local lastVal = 0
        for _, cp in ipairs(commaParts) do
            lastVal = evaluateArithmetic(cp, getenv)
        end

        return lastVal
    end

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
            if rhs == 0 then newv = 0 else newv = DIV(cur, rhs) end
        elseif aop == "%" then
            if rhs == 0 then newv = 0 else newv = MOD(cur, rhs) end
        end

        if st().readonlys[aname] then
            wasReadonly(aname)
            return newv
        end

        st().locals[aname] = tostring(newv)
        return newv
    end

    local pname = expr:match("^%s*([%a_][%w_]*)%+%+%s*$")
    local dname = expr:match("^%s*([%a_][%w_]*)%-%-%s*$")
    if pname or dname then
        local nm = pname or dname
        local cur = math.floor(tonumber(lookupVar(nm, getenv)) or 0)
        if st().readonlys[nm] then
            wasReadonly(nm)
            return cur
        end

        st().locals[nm] = tostring(cur + (pname and 1 or -1))
        return cur
    end

    pname = expr:match("^%s*%+%+([%a_][%w_]*)%s*$")
    dname = expr:match("^%s*%-%-([%a_][%w_]*)%s*$")
    if pname or dname then
        local nm = pname or dname
        local cur = math.floor(tonumber(lookupVar(nm, getenv)) or 0) + (pname and 1 or -1)
        if st().readonlys[nm] then
            wasReadonly(nm)
            return cur
        end

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
    -- Why lua must you not use C style stuff natively? WHY
    local function getOperandLeft(s, endIdx)
        local b = endIdx
        while b >= 1 and s:sub(b, b) == " " do b = b - 1 end
        if b < 1 then return nil end
        local a
        if s:sub(b, b) == ")" then
            local d = 0
            a = b
            while a >= 1 do
                local cc = s:sub(a, a)
                if cc == ")" then
                    d = d + 1
                elseif cc == "(" then
                    d = d - 1
                    if d == 0 then break end
                end
                a = a - 1
            end

            if a < 1 then return nil end
            -- I learned what a callee prefix is wow
            while a > 1 and s:sub(a - 1, a - 1):match("[%w%.]") do
                a = a - 1
            end
        else
            a = b
            while a >= 1 and s:sub(a, a):match("[%w%.]") do
                a = a - 1
            end
            a = a + 1
            if a > b then return nil end
        end
        -- Give me a sign
        while a > 1 and (s:sub(a - 1, a - 1) == "-" or s:sub(a - 1, a - 1) == "+") do
            local before = (a - 2 >= 1) and s:sub(a - 2, a - 2) or ""
            if before:match("[%w%._%)]") then break end
            a = a - 1
        end

        return a, b
    end

    local function getRight(s, opIdx)
        local a = opIdx + 1
        while a <= #s and s:sub(a, a) == " " do
            a = a + 1
        end
        if a > #s then return nil end
        local b = a
        -- n ** -(n + n)
        while s:sub(b, b) == "-" or s:sub(b, b) == "+" do
            b = b + 1
        end
        if s:sub(b, b) == "(" then
            local d, j = 0, b
            while j <= #s do
                local cc = s:sub(j, j)
                if cc == "(" then
                    d = d + 1
                elseif cc == ")" then
                    d = d - 1
                    if d == 0 then break end
                end
                j = j + 1
            end

            return a, j
        end
        while b <= #s and s:sub(b, b):match("[%w%.]") do
            b = b + 1
        end
        -- just one
        if s:sub(b, b) == "(" then
            local d, j = 0, b
            while j <= #s do
                local cc = s:sub(j, j)
                if cc == "(" then
                    d = d + 1
                elseif cc == ")" then
                    d = d - 1
                    if d == 0 then
                        b = j + 1
                        break
                    end
                end
                j = j + 1
            end
        end
        b = b - 1
        if b < a then return nil end

        return a, b
    end

    -- Whats on the left?
    local function getLeft(s, ops)
        ops = ops or "*/%"
        local a = getOperandLeft(s, #s)
        if not a then return nil end
        while true do
            local k = a - 1
            while k >= 1 and s:sub(k, k) == " " do
                k = k - 1
            end

            local c = k >= 1 and s:sub(k, k) or ""
            if c ~= "" and ops:find(c, 1, true) then
                local a2 = getOperandLeft(s, k - 1)
                if not a2 then
                    break
                end
                a = a2
            else
                break
            end
        end

        return a
    end

    local function dealWithDivMod(e)
        local acc = ""
        local i = 1
        while i <= #e do
            local c = e:sub(i, i)
            if c == "(" then
                -- you okay nest?
                local d, j = 0, i
                while j <= #e do
                    local cc = e:sub(j, j)
                    if cc == "(" then
                        d = d + 1
                    elseif cc == ")" then
                        d = d - 1
                        if d == 0 then break end
                    end
                    j = j + 1
                end

                acc = acc .. "(" .. dealWithDivMod(e:sub(i + 1, j - 1)) .. ")"
                i = j + 1
            elseif (c == "/" or c == "%")
                and not (c == "/" and e:sub(i + 1, i + 1) == "/") then
                local ca, cb = getRight(e, i)
                local aStart = ca and getLeft(acc) or nil
                if aStart then
                    local left = acc:sub(aStart)
                    local right = e:sub(ca, cb)
                    local piece = (c == "/" and "DIV(" or "MOD(") ..
                        left .. "," .. right .. ")"
                    acc = acc:sub(1, aStart - 1) .. piece
                    i = cb + 1
                else
                    acc = acc .. c
                    i = i + 1
                end
            else
                acc = acc .. c
                i = i + 1
            end
        end

        return acc
    end

    -- Its because of things on the right
    local function matchParenAt(e, start)
        local d = 0
        for j = start, #e do
            local cc = e:sub(j, j)
            if cc == "(" then
                d = d + 1
            elseif cc == ")" then
                d = d - 1
                if d == 0 then return j end
            end
        end

        return nil
    end

    local function dealWithPow(e)
        local acc = {}
        local n = #e
        local i = 1
        while i <= n do
            local c = e:sub(i, i)
            if c == "(" then
                local j = matchParenAt(e, i)
                if not j then
                    acc[#acc + 1] = e:sub(i)
                    break
                end
                acc[#acc + 1] = "(" .. dealWithPow(e:sub(i + 1, j - 1)) .. ")"
                i = j + 1
            elseif c == "*" and e:sub(i + 1, i + 1) == "*" then
                local accStr = table.concat(acc)
                local aStart = #accStr > 0 and getOperandLeft(accStr, #accStr) or nil
                if not aStart then
                    acc[#acc + 1] = "**"
                    i = i + 2
                else
                    -- Its because of **
                    local primaries = {}
                    local p = i + 2
                    while true do
                        while p <= n and e:sub(p, p) == " " do p = p + 1 end
                        local primStart = p
                        while p <= n and (e:sub(p, p) == "-" or e:sub(p, p) == "+") do
                            p = p + 1
                            while p <= p and p <= n and e:sub(p, p) == " " do p = p + 1 end
                        end

                        local coreStart = p
                        local core = nil
                        if p <= n and e:sub(p, p) == "(" then
                            local j = matchParenAt(e, p)
                            if j then
                                core = "(" .. dealWithPow(e:sub(p + 1, j - 1)) .. ")"
                                p = j + 1
                            end
                        else
                            while p <= n and e:sub(p, p):match("[%w%.]") do
                                p = p + 1
                            end
                            if p > coreStart then
                                core = e:sub(coreStart, p - 1)
                            end
                        end

                        if not core then
                            ---@diagnostic disable-next-line: cast-local-type
                            p = nil -- This causes problems
                            break
                        end

                        primaries[#primaries + 1] = e:sub(primStart, coreStart - 1) .. core
                        local q = p
                        while q <= n and e:sub(q, q) == " " do q = q + 1 end
                        if e:sub(q, q + 1) == "**" then
                            p = q + 2
                        else
                            break
                        end
                    end
                    if not p then
                        acc[#acc + 1] = "**"
                        i = i + 2
                    else
                        local right = primaries[#primaries]
                        for k = #primaries - 1, 1, -1 do
                            right = "POW(" .. primaries[k] .. "," .. right .. ")"
                        end

                        acc = {
                            accStr:sub(1, aStart - 1) ..
                            "POW(" .. accStr:sub(aStart) .. "," .. right .. ")"
                        }
                        i = p
                    end
                end
            else
                acc[#acc + 1] = c
                i = i + 1
            end
        end

        return table.concat(acc)
    end

    expr = dealWithPow(expr)

    expr = dealWithDivMod(expr)

    -- Because of ^
    local function dealWithXor(e)
        local acc = ""
        local i = 1
        while i <= #e do
            local c = e:sub(i, i)
            if c == "(" then
                local j = matchParenAt(e, i)
                if not j then
                    acc = acc .. e:sub(i)
                    break
                end

                acc = acc .. "(" .. dealWithXor(e:sub(i + 1, j - 1)) .. ")"
                i = j + 1
            elseif c == "^" then
                local ca, cb = getRight(e, i)
                local aStart = ca and getLeft(acc, "+-*/%") or nil
                if aStart then
                    local left = acc:sub(aStart)
                    local right = e:sub(ca, cb)
                    acc = acc:sub(1, aStart - 1) .. "XOR(" .. left .. "," .. right .. ")"
                    i = cb + 1
                else
                    acc = acc .. c
                    i = i + 1
                end
            else
                acc = acc .. c
                i = i + 1
            end
        end

        return acc
    end
    expr = dealWithXor(expr)

    -- Who even uses this? I guess me
    local function dealWithTernary(e)
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
        local cond = dealWithTernary(e:sub(1, qpos - 1))
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
        -- You are not the chosen one
        return "TERN(" .. cond .. ",function() return " ..
            dealWithTernary(e:sub(qpos + 1, colon - 1)) .. " end,function() return " ..
            dealWithTernary(e:sub(colon + 1)) .. " end)"
    end
    expr = dealWithTernary(expr)

    -- Of course math has || and && in it. Why wouldnt it. Lovely
    local function dealWithLogic(e, top)
        local orParts = splitTopLevel(e, "||")
        local andParts = not orParts and splitTopLevel(e, "&&") or nil

        if orParts or andParts then
            local t = {}
            for i, p in ipairs(orParts or andParts) do
                t[i] = "TB((" .. dealWithLogic(p) .. "))"
            end

            local joined = table.concat(t, orParts and " or " or " and ")
            return top and ("TN(" .. joined .. ")") or joined
        end

        local n, i = #e, 1
        local buf = {}
        -- This hopefully wont fail?
        while i <= n do
            local c = e:sub(i, i)
            if c == "(" then
                local depth, j = 1, i + 1
                while j <= n and depth > 0 do
                    local d = e:sub(j, j)
                    if d == "(" then
                        depth = depth + 1
                    elseif d == ")" then
                        depth = depth - 1
                    end
                    j = j + 1
                end

                local inner = e:sub(i + 1, j - 2)
                local segs, cur, sd = {}, {}, 0
                for ci = 1, #inner do
                    local d = inner:sub(ci, ci)
                    if d == "(" then
                        sd = sd + 1
                    elseif d == ")" then
                        sd = sd - 1
                    end
                    if sd == 0 and d == "," then
                        segs[#segs + 1] = table.concat(cur)
                        cur = {}
                    else
                        cur[#cur + 1] = d
                    end
                end
                segs[#segs + 1] = table.concat(cur)

                local tr = {}
                for si, s in ipairs(segs) do
                    tr[si] = dealWithLogic(s, true)
                end

                buf[#buf + 1] = "(" .. table.concat(tr, ",") .. ")"
                i = j
            else
                buf[#buf + 1] = c
                i = i + 1
            end
        end
        return table.concat(buf)
    end
    expr = dealWithLogic(expr, true)

    -- Kindly dont crash my shell though. MShell sure got that wrong...
    local fn, err = load("return " .. expr, "=arithmetic", "t",
        { math = math, POW = POW, XOR = XOR, TERN = TERN, TB = TB, TN = TN, DIV = DIV, MOD = MOD })
    if not fn then
        writeRed(process.error(), "ksh: arithmetic error: " .. tostring(err), "\n")
        return 0
    end

    local ok, result = pcall(fn)
    if not ok then
        writeRed(process.error(), "ksh: arithmetic error: " .. tostring(result), "\n")
        if ctx.isRunningScript() then ctx.setFatal() end
        return 0
    end
    if result == true then return 1 end
    if result == false then return 0 end
    return math.floor(tonumber(result) or 0)
end

return {
    init = function(c) ctx = c end,
    eval = evaluateArithmetic,
}
