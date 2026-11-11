-- /lib/ksh/parser/brace.lua
-- for {braces}
-- I just copied it outside to save ram. And easier to read? Hopefully?
local function expandBraceToken(str)
    -- { braces without quotes }
    local function findGroupEnd(s, start)
        local depth, dbr, pdepth = 1, 0, 0
        local sq, dq, esc = false, false, false
        local dollarPending = false
        local j = start + 1
        while j <= #s do
            local c = s:sub(j, j)
            if esc then
                esc = false
                dollarPending = false
            elseif c == "\\" then
                esc = true
                dollarPending = false
            elseif sq then
                if c == "'" then sq = false end
                dollarPending = false
            elseif dq then
                if c == '"' then dq = false end
                dollarPending = false
            elseif c == "'" then
                sq = true
                dollarPending = false
            elseif c == '"' then
                dq = true
                dollarPending = false
            elseif dbr > 0 then
                if c == "{" then
                    dbr = dbr + 1
                elseif c == "}" then
                    dbr = dbr - 1
                end
                dollarPending = false
            elseif pdepth > 0 then
                if c == "(" then
                    pdepth = pdepth + 1
                elseif c == ")" then
                    pdepth = pdepth - 1
                end
                dollarPending = false
            elseif c == "$" then
                dollarPending = true
            elseif c == "{" and dollarPending then
                dbr = 1
                dollarPending = false
            elseif c == "(" and dollarPending then
                pdepth = 1
                dollarPending = false
            elseif c == "(" then
                pdepth = pdepth + 1
                dollarPending = false
            elseif c == "{" then
                depth = depth + 1
                dollarPending = false
            elseif c == "}" then
                depth = depth - 1
                if depth == 0 then
                    return j
                end
                dollarPending = false
            else
                dollarPending = false
            end
            j = j + 1
        end
        return nil
    end

    local function splitTopCommas(body)
        local parts = { "" }
        local cur = 1
        local depth, dbr, pdepth = 0, 0, 0
        local sq, dq, esc = false, false, false
        local dollarPending = false
        for k = 1, #body do
            local c = body:sub(k, k)
            local skip = false
            if esc then
                esc = false
                dollarPending = false
            elseif c == "\\" then
                esc = true
                dollarPending = false
            elseif sq then
                if c == "'" then sq = false end
                dollarPending = false
            elseif dq then
                if c == '"' then dq = false end
                dollarPending = false
            elseif c == "'" then
                sq = true
                dollarPending = false
            elseif c == '"' then
                dq = true
                dollarPending = false
            elseif dbr > 0 then
                if c == "{" then
                    dbr = dbr + 1
                elseif c == "}" then
                    dbr = dbr - 1
                end
                dollarPending = false
            elseif pdepth > 0 then
                if c == "(" then
                    pdepth = pdepth + 1
                elseif c == ")" then
                    pdepth = pdepth - 1
                end
                dollarPending = false
            elseif c == "$" then
                dollarPending = true
            elseif c == "{" and dollarPending then
                dbr = 1
                dollarPending = false
            elseif c == "(" and dollarPending then
                pdepth = 1
                dollarPending = false
            elseif c == "(" then
                pdepth = pdepth + 1
                dollarPending = false
            elseif c == "{" then
                depth = depth + 1
                dollarPending = false
            elseif c == "}" then
                if depth > 0 then depth = depth - 1 end
                dollarPending = false
            elseif c == "," and depth == 0 and pdepth == 0 then
                cur = cur + 1
                parts[cur] = ""
                dollarPending = false
                skip = true
            else
                dollarPending = false
            end
            if not skip then
                parts[cur] = parts[cur] .. c
            end
        end
        if #parts > 1 then
            return parts
        end
        return nil
    end

    -- Seq
    local function rangeItems(ra, rb, rs)
        local na, nb = tonumber(ra), tonumber(rb)
        if na and nb then
            local items = {}
            local width = 0
            if ra:sub(1, 1) == "0" or rb:sub(1, 1) == "0" then
                width = math.max(#ra, #rb)
            end
            -- Mmmmm larp being like bash
            if ra:sub(1, 1) == "-" or rb:sub(1, 1) == "-" then
                width = width + 1
            end

            local step = 1
            if rs then
                step = math.floor(math.abs(tonumber(rs) or 0))
                if step == 0 then step = 1 end
            end

            local v = na
            if na <= nb then
                while v <= nb do
                    items[#items + 1] = string.format("%0" .. width .. "d", v)
                    v = v + step
                end
            else
                while v >= nb do
                    items[#items + 1] = string.format("%0" .. width .. "d", v)
                    v = v - step
                end
            end
            return items
        end
        if #ra == 1 and #rb == 1 then
            local ca, cb = ra:byte(), rb:byte()
            local aLetter = (ca >= 65 and ca <= 90) or (ca >= 97 and ca <= 122)
            local bLetter = (cb >= 65 and cb <= 90) or (cb >= 97 and cb <= 122)
            if aLetter and bLetter then
                local items = {}
                local step = 1
                if rs then
                    step = math.floor(math.abs(tonumber(rs) or 0))
                    if step == 0 then step = 1 end
                end

                local v = ca
                if ca <= cb then
                    while v <= cb do
                        items[#items + 1] = string.char(v)
                        v = v + step
                    end
                else
                    while v >= cb do
                        items[#items + 1] = string.char(v)
                        v = v - step
                    end
                end

                return items
            end
        end
        return nil
    end

    local expandOne, expandGroup
    expandGroup = function(s, open, close, items)
        local prefix = s:sub(1, open - 1)
        local suffix = s:sub(close + 1)
        local out = {}
        for _, item in ipairs(items) do
            for _, r in ipairs(expandOne(prefix .. item .. suffix)) do
                out[#out + 1] = r
            end
        end
        return out
    end

    -- Easy
    expandOne = function(s)
        local i = 1
        local esc = false
        local sq, dq = false, false
        local dbr, pdepth = 0, 0
        local dollarPending = false
        while i <= #s do
            local c = s:sub(i, i)
            if esc then
                esc = false
                dollarPending = false
                i = i + 1
            elseif c == "\\" then
                esc = true
                dollarPending = false
                i = i + 1
            elseif sq then
                if c == "'" then sq = false end
                dollarPending = false
                i = i + 1
            elseif dq then
                if c == '"' then dq = false end
                dollarPending = false
                i = i + 1
            elseif c == "'" then
                sq = true
                dollarPending = false
                i = i + 1
            elseif c == '"' then
                dq = true
                dollarPending = false
                i = i + 1
            elseif dbr > 0 then
                if c == "{" then
                    dbr = dbr + 1
                elseif c == "}" then
                    dbr = dbr - 1
                end
                dollarPending = false
                i = i + 1
            elseif pdepth > 0 then
                if c == "(" then
                    pdepth = pdepth + 1
                elseif c == ")" then
                    pdepth = pdepth - 1
                end
                dollarPending = false
                i = i + 1
            elseif c == "$" then
                dollarPending = true
                i = i + 1
            elseif c == "{" and dollarPending then
                dbr = 1
                dollarPending = false
                i = i + 1
            elseif c == "(" and dollarPending then
                pdepth = 1
                dollarPending = false
                i = i + 1
            elseif c == "{" then
                dollarPending = false
                local close = findGroupEnd(s, i)
                if close then
                    local body = s:sub(i + 1, close - 1)
                    local exp = splitTopCommas(body)
                    if not exp then
                        local ra, rb, rs = body:match("^(.-)%.%.(.-)%.%.(.+)$")
                        if ra then
                            exp = rangeItems(ra, rb, rs)
                        else
                            local ra2, rb2 = body:match("^(.-)%.%.(.+)$")
                            if ra2 then
                                exp = rangeItems(ra2, rb2, nil)
                            end
                        end
                    end

                    if exp then
                        return expandGroup(s, i, close, exp)
                    end
                end

                i = i + 1
            else
                dollarPending = false
                i = i + 1
            end
        end
        return { s }
    end

    local parts = expandOne(str)
    -- {,} will stay though
    if #parts > 1 then
        local allEmpty = true
        for _, p in ipairs(parts) do
            if p ~= "" then
                allEmpty = false
                break
            end
        end
        if not allEmpty then
            local out = {}
            for _, p in ipairs(parts) do
                if p ~= "" then
                    out[#out + 1] = p
                end
            end

            return out
        end
    end
    return parts
end

return { expand = expandBraceToken }
