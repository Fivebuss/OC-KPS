-- Ported from openOS and I stripped out streams as I have no use for them.
-- Also I added &N> support

local unicode = require("unicode")

local text = {}
text.internal = {}

-- Shell syntax
-- Added my own extras: Backgrounding and redirection, subshell stuff

text.syntax = {
    "&%d+>>", -- &N>>
    "&%d+>",  -- &N>
    "&%d+<",  -- &N<
    "&%d+",   -- &N  (fd)
    "&&",     -- &&

    "%d+>>",  -- N>>
    "%d+>",   -- N>
    "%d+<",   -- N<

    "<<<",    -- <<<
    ">>",     -- >>
    ">",      -- >
    "<",      -- <

    "&",      -- background
    ";",      -- command separator
    "||",     -- ||
    "|",      -- |

    "%$%(%(", -- $(( math
    "%$%(",   -- $(  substitution
    "%(",     -- (   subshell
    "%)"      -- )   end subshell
}

-- Trim whitespace from both ends of a string
function text.trim(value)
    local from = string.match(value, "^%s*()")
    return from > #value and "" or string.match(value, ".*%S", from)
end

-- Escape Lua pattern stuff
function text.escapeMagic(txt)
    return txt:gsub('[%(%)%.%%%+%-%*%?%[%^%$]', '%%%1')
end

-- Remove escaping
function text.removeEscapes(txt)
    return txt:gsub("%%([%(%)%.%%%+%-%*%?%[%^%$])", "%1")
end

function text.split(input, delimiters, dropDelims, di)
    checkArg(1, input, "string")
    checkArg(2, delimiters, "table")
    checkArg(3, dropDelims, "boolean", "nil")
    checkArg(4, di, "number", "nil")

    if #input == 0 then
        return {}
    end

    di = di or 1

    local result = { input }

    if di > #delimiters then
        return result
    end

    local function add(part, index, recurse, s, e)
        local sub = part:sub(s, e)

        if #sub == 0 then
            return index
        end

        local subs = recurse
            and text.split(sub, delimiters, dropDelims, recurse)
            or { sub }

        for i = 1, #subs do
            table.insert(result, index + i - 1, subs[i])
        end

        return index + #subs
    end

    local i = 1
    local d = delimiters[di]

    while true do
        local next = table.remove(result, i)

        if not next then
            break
        end

        local si, ei = next:find(d)

        if si and ei and ei ~= 0 then
            i = add(next, i, di + 1, 1, si - 1)

            if dropDelims then
                -- Don't add delimiter.
            else
                i = add(next, i, false, si, ei)
            end

            i = add(next, i, di, ei + 1, #next)
        else
            i = add(next, i, di + 1, 1, #next)
        end
    end

    return result
end

-- Split strings by delimiters
local function findDelimiter(txt, delimiters, start)
    local bestS
    local bestE
    local bestLen

    for i = 1, #delimiters do
        local s, e = txt:find(delimiters[i], start)

        if s and (
                not bestS
                or s < bestS
                or (s == bestS and (e - s) > bestLen)
            ) then
            bestS = s
            bestE = e
            bestLen = e - s
        end
    end

    return bestS, bestE
end

-- Tokenize
-- Again.
function text.internal.tokenize(value, options)
    checkArg(1, value, "string")
    checkArg(2, options, "table", "nil")

    options = options or {}

    local delimiters = options.delimiters or text.syntax
    local quotes = options.quotes or {
        { "'", "'", true },
        { '"', '"' },
        { '`', '`' }
    }
    local showEscapes = options.show_escapes

    local words = {}
    local buf = {}
    local mask = {}

    local frames = {}
    local depth = 0
    local prevDollar = false
    local dbrace = 0
    local escaped = false

    local function emit(ch, unquoted)
        buf[#buf + 1] = ch
        for _ = 1, #ch do
            mask[#mask + 1] = unquoted
        end
    end

    local function flushWord()
        if #buf > 0 then
            words[#words + 1] = { text = table.concat(buf), mask = mask }
            buf = {}
            mask = {}
        end
    end

    -- This gives me headaches
    for i = 1, unicode.len(value) do
        local char = unicode.sub(value, i, i)
        local top = frames[#frames]
        local topq = top and top.q or nil
        local qhere = (top and top.lvl == depth) and topq or nil
        local unquoted = (#frames == 0)

        if dbrace > 0 and char == "}" then
            dbrace = dbrace - 1
        end
        if prevDollar and char == "{" then
            dbrace = dbrace + 1
        end

        if escaped then
            escaped = false
            prevDollar = false

            if showEscapes or dbrace > 0 or (topq and not topq[3]) or
                char == "$" or char == "{" or char == "}" or char == "," then
                emit("\\", unquoted)
            end

            emit(char, unquoted)
        elseif char == "\\" and (not topq or not topq[3]) then
            escaped = true
            prevDollar = false
        elseif char == "(" then
            if qhere and not (prevDollar and not qhere[3]) then
                emit(char, unquoted)
            else
                depth = depth + 1
                emit(char, unquoted)
            end
            prevDollar = false
        elseif char == ")" then
            if qhere then
                emit(char, unquoted)
            else
                if depth > 0 then depth = depth - 1 end
                emit(char, unquoted)
            end
            prevDollar = false
        elseif qhere and topq[2] == char then
            emit(topq[2], false)
            table.remove(frames)
            prevDollar = false
        elseif qhere then
            emit(char, unquoted)
            prevDollar = (char == "$")
        elseif unquoted and string.find(char, "%s") then
            flushWord()
            prevDollar = false
        else
            local rec
            for k = 1, #quotes do
                if quotes[k][1] == char then
                    rec = quotes[k]
                    break
                end
            end

            if rec then
                frames[#frames + 1] = { q = rec, lvl = depth, pos = i } -- fix
                emit(rec[1], false)
                prevDollar = false
            else
                emit(char, unquoted)
                prevDollar = (char == "$")
            end
        end
    end

    if #frames > 0 then
        return nil, "unclosed quote at index " .. frames[1].pos
    end

    flushWord()

    local tokens = {}

    -- aaa utf 8 how I hate you
    for _, word in ipairs(words) do
        local source = word.text
        local quoted = word.mask
        local seg = {}
        local segLen = 0

        local function flushSeg()
            if segLen > 0 then
                tokens[#tokens + 1] = table.concat(seg)
                seg = {}
                segLen = 0
            end
        end
        -- yay its less memory
        local i = 1
        while i <= #source do
            local matched
            if quoted[i] then
                local ds, de = findDelimiter(source, delimiters, i)
                if ds == i then matched = de end
            end

            if matched then
                flushSeg()
                tokens[#tokens + 1] = source:sub(i, matched)
                i = matched + 1
            else
                seg[#seg + 1] = source:sub(i, i)
                segLen = segLen + 1
                i = i + 1
            end
        end

        flushSeg()
    end

    return tokens
end

function text.tokenize(value, options)
    checkArg(1, value, "string")
    checkArg(2, options, "table", "nil")

    return text.internal.tokenize(value, options or {})
end

-- Deal with braces
function text.internal.braceGroups(tokens)
    checkArg(1, tokens, "table")

    local function parse(list, i, inner)
        local out = {}
        local n = #list
        local commandStart = true

        while i <= n do
            local tok = list[i]

            if type(tok) == "string" and tok == "{" and commandStart then
                local nested, nextIndex = parse(list, i + 1, true)
                if not nested then return nil, nextIndex end
                out[#out + 1] = { braceGroup = nested }
                i = nextIndex
                commandStart = false
            elseif type(tok) == "string" and tok == "}" and commandStart then
                if inner then
                    local last = out[#out]
                    if not last then return nil, "empty { } list" end
                    if last ~= ";" and last ~= "&" then
                        return nil, "missing ';' before '}'"
                    end
                    return out, i + 1
                end

                return nil, "unexpected '}'"
            elseif type(tok) == "string" and
                (tok == ";" or tok == "&" or tok == "&&" or tok == "||" or tok == "|") then
                if commandStart then return nil, "unexpected '" .. tok .. "'" end
                out[#out + 1] = tok
                commandStart = true
                i = i + 1
            else
                out[#out + 1] = tok
                commandStart = false
                i = i + 1
            end
        end

        if inner then return nil, "missing '}'" end
        return out
    end

    return parse(tokens, 1, false)
end

-- Formatting

-- Convert tabs into spaces.
function text.detab(value, tabWidth)
    checkArg(1, value, "string")
    checkArg(2, tabWidth, "number", "nil")

    tabWidth = tabWidth or 8

    local function rep(match)
        local spaces = tabWidth - match:len() % tabWidth
        return match .. string.rep(" ", spaces)
    end

    return value:gsub("([^\n]-)\t", rep)
end

-- Padding

function text.padLeft(value, length)
    checkArg(1, value, "string", "nil")
    checkArg(2, length, "number")

    if not value or unicode.wlen(value) == 0 then
        return string.rep(" ", length)
    end

    return string.rep(
        " ",
        length - unicode.wlen(value)
    ) .. value
end

function text.padRight(value, length)
    checkArg(1, value, "string", "nil")
    checkArg(2, length, "number")

    if not value or unicode.wlen(value) == 0 then
        return string.rep(" ", length)
    end

    return value .. string.rep(
        " ",
        length - unicode.wlen(value)
    )
end

-- Wordwrap

function text.wrap(value, width, maxWidth)
    checkArg(1, value, "string")
    checkArg(2, width, "number")
    checkArg(3, maxWidth, "number")

    -- Read up to the next nl
    local line, nl = value:match("([^\r\n]*)(\r?\n?)")

    -- No wrapping needed for this
    if unicode.wlen(line) <= width then
        local start =
            unicode.len(line) +
            unicode.len(nl) +
            1

        return
            line,
            start <= unicode.len(value)
            and unicode.sub(value, start)
            or nil,
            unicode.len(nl) > 0
    end

    -- Line is too long
    local partial = unicode.wtrunc(line, width)

    -- Try to break up at a realistic area
    local wrapped =
        partial:match("(.*[^a-zA-Z0-9._()'`=])")

    if wrapped or unicode.wlen(line) > maxWidth then
        partial = wrapped or partial

        return
            partial,
            unicode.sub(
                value,
                unicode.len(partial) + 1
            ),
            true
    else
        -- Dont split for the sake of it
        return "", value, true
    end
end

-- String handlers because useful for devfs
function text.internal.reader(data, mode)
    data = data or ""
    local pos = 1
    return {
        read = function(_, n)
            n = n or math.huge
            if pos > #data then return nil end
            local chunk = data:sub(pos, pos + n - 1)
            pos = pos + #chunk
            return chunk
        end,
        close = function() end
    }
end

function text.internal.writer(write, mode, existing)
    if mode:match("a") and existing then
        write(existing)
    end
    return {
        write = function(_, value)
            return write(value)
        end,
        close = function() end
    }
end

-- Wrapped lines again

function text.wrappedLines(value, width, maxWidth)
    local line

    return function()
        if value then
            line, value = text.wrap(
                value,
                width,
                maxWidth
            )

            return line
        end
    end
end

return text
