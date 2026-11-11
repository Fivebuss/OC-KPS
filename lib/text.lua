-- Ported from openOS and I stripped out streams as I have no use for them.
-- Also I added &N> support

local unicode = require("unicode")
local tx = require("transforms")

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

-- Tokenize

-- Separate a string into an array of words delimited by whitespace
-- Groups quoted text into a single word
--
-- options:
-- delimiters    custom shell delimiters
-- quotes        custom quote definitions
-- show_escapes  preserve backslash escape characters
-- doNotNormalize
function text.tokenize(value, options)
    checkArg(1, value, "string")
    checkArg(2, options, "table", "nil")

    options = options or {}

    local tokens, reason = text.internal.tokenize(value, options)

    if type(tokens) ~= "table" then
        return nil, reason
    end

    if options.doNotNormalize then
        return tokens
    end

    return text.internal.normalize(tokens)
end

function text.internal.tokenize(value, options)
    checkArg(1, value, "string")
    checkArg(2, options, "table", "nil")

    options = options or {}

    local delimiters = options.delimiters
    local custom = not not delimiters

    delimiters = delimiters or text.syntax

    local words, reason = text.internal.words(value, options)

    local splitter = text.escapeMagic(
        custom and table.concat(delimiters) or "<>|;&()"
    )

    if type(words) ~= "table" or
        #splitter == 0 or
        not value:find("[" .. splitter .. "]") then
        return words, reason
    end

    return text.internal.splitWords(words, delimiters)
end

function text.internal.words(input, options)
    checkArg(1, input, "string")
    checkArg(2, options, "table", "nil")

    options = options or {}

    local quotes = options.quotes
    local show_escapes = options.show_escapes


    quotes = quotes or {
        { "'", "'", true },
        { '"', '"' },
        { '`', '`' }
    }

    local function append(dst, txt, stk, fref)
        local size = #dst

        if size == 0 or dst[size].fref ~= fref then
            dst[size + 1] = {
                txt = txt,
                qr = fref and fref.q or nil,
                stk = stk,
                fref = fref
            }
        else
            dst[size].txt = dst[size].txt .. txt
        end
    end

    -- qr quot rules

    local tokens = {}
    local token = {}

    -- Oh look subshells continue to ruin my day
    local frames = {}
    local depth = 0
    local prevDollar = false
    local dbrace = 0

    local escaped = false

    -- You know what? Fine. Il do it this way.
    local function currentStack()
        if #frames == 0 then return nil end
        local stk = {}
        for k = 1, #frames do
            stk[k] = frames[k]
        end
        return stk
    end

    for i = 1, unicode.len(input) do
        local char = unicode.sub(input, i, i)

        local top = frames[#frames]
        local topq = top and top.q or nil
        local qhere = (top and top.lvl == depth) and topq or nil

        if dbrace > 0 and char == "}" then
            dbrace = dbrace - 1
        end
        if prevDollar and char == "{" then
            dbrace = dbrace + 1
        end

        if escaped then
            escaped = false
            prevDollar = false

            -- Escape handling
            -- again. It was broken horrificly
            if show_escapes or dbrace > 0 or (topq and not topq[3]) or char == "$"
                or char == "{" or char == "}" or char == "," then
                append(token, "\\", top and currentStack(), top)
            end

            append(token, char, top and currentStack(), top)
        elseif char == "\\" and (not topq or not topq[3]) then
            escaped = true
            prevDollar = false
        elseif char == "(" then
            -- "$("
            if qhere and not (prevDollar and not qhere[3]) then
                append(token, char, top and currentStack(), top)
            else
                depth = depth + 1
                append(token, char, top and currentStack(), top)
            end
            prevDollar = false
        elseif char == ")" then
            if qhere then
                append(token, char, top and currentStack(), top)
            else
                if depth > 0 then
                    depth = depth - 1
                end
                append(token, char, top and currentStack(), top)
            end
            prevDollar = false
        elseif qhere and topq[2] == char then
            if not top.nparts or top.nparts == 0 then
                append(token, "", top and currentStack(), top)
            end
            table.remove(frames)
            prevDollar = false
        elseif qhere then
            if not top.nparts then top.nparts = 0 end
            top.nparts = top.nparts + 1
            append(token, char, top and currentStack(), top)
            prevDollar = (char == "$")
        elseif #frames == 0 and string.find(char, "%s") then
            if #token > 0 then
                table.insert(tokens, token)
            end

            token = {}
            prevDollar = false
        else
            local rec
            tx.first(quotes, function(Q)
                rec = Q[1] == char and Q or nil
                return rec
            end)
            if rec then
                table.insert(frames, { q = rec, lvl = depth, pos = i })
                prevDollar = false
            else
                if top then
                    if not top.nparts then top.nparts = 0 end
                    top.nparts = top.nparts + 1
                end
                append(token, char, top and currentStack(), top)
                prevDollar = (char == "$")
            end
        end
    end

    if #frames > 0 then
        return nil, "unclosed quote at index " .. frames[1].pos
    end

    if #token > 0 then
        table.insert(tokens, token)
    end

    return tokens
end

-- Split strings by delimiters
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

-- Split at shell delimit
function text.internal.splitWords(words, delimiters)
    checkArg(1, words, "table")
    checkArg(2, delimiters, "table")

    local split_words = {}

    local function add_word(word)
        if #word > 0 then
            split_words[#split_words + 1] = word
        end
    end

    -- Find the earliest delimiter at or after start, if multiple use longest
    local function find_delimiter(txt, start)
        local best_s
        local best_e
        local best_len

        for i = 1, #delimiters do
            local pattern = delimiters[i]
            local s, e = txt:find(pattern, start)

            if s and (
                    not best_s
                    or s < best_s
                    or (s == best_s and (e - s) > best_len)
                ) then
                best_s = s
                best_e = e
                best_len = e - s
            end
        end

        return best_s, best_e
    end

    for wi = 1, #words do
        local word = words[wi]

        -- quoted shouldnt be shell stuff
        local current = {}

        local function flush()
            if #current > 0 then
                add_word(current)
                current = {}
            end
        end

        for pi = 1, #word do
            local part = word[pi]

            if part.qr then
                -- And here either
                current[#current + 1] = part
            else
                local txt = part.txt
                local pos = 1

                while pos <= #txt do
                    local s, e = find_delimiter(txt, pos)

                    if not s then
                        if pos <= #txt then
                            current[#current + 1] = {
                                txt = txt:sub(pos),
                                qr = nil
                            }
                        end
                        break
                    end

                    -- Before operator text?
                    if s > pos then
                        current[#current + 1] = {
                            txt = txt:sub(pos, s - 1),
                            qr = nil
                        }
                    end

                    flush()

                    current[#current + 1] = {
                        txt = txt:sub(s, e),
                        qr = nil
                    }

                    flush()

                    pos = e + 1
                end
            end
        end

        flush()
    end

    return split_words
end

-- Parse/normalize tokens

function text.internal.normalize(words, omitQuotes)
    checkArg(1, words, "table")
    checkArg(2, omitQuotes, "boolean", "nil")

    local norms = {}

    -- I DESPISE QUOTES. THIS TOOK AN HOUR AND A HALF TO FIX
    -- but now \n works in things. Worth it (it wasn't)
    for _, word in ipairs(words) do
        local norm = {}
        local stack = {}

        local function emit(v)
            norm[#norm + 1] = v
        end

        local function closeThrough(to)
            while #stack > to do
                if not omitQuotes then
                    emit(stack[#stack].q[2])
                end
                table.remove(stack)
            end
        end

        local function openThrough(st)
            for k = #stack + 1, #st do
                local f = st[k]
                if not omitQuotes then
                    emit(f.q[1])
                end
                stack[#stack + 1] = f
            end
        end

        -- Cursed
        for _, part in ipairs(word) do
            local st = part.stk or {}

            local prefix = 0
            while prefix < #stack and prefix < #st and st[prefix + 1] == stack[prefix + 1] do
                prefix = prefix + 1
            end
            closeThrough(prefix)
            openThrough(st)

            emit(part.txt)
        end

        closeThrough(0)

        norms[#norms + 1] = table.concat(norm)
    end

    return norms
end

-- Deal with braces
local function parseBraceList(tokens, i)
    local inner = {}
    local n = #tokens
    local commandStart = true

    while i <= n do
        local tok = tokens[i]

        if type(tok) == "string" and tok == "{" and commandStart then
            local nested, nextIndex = parseBraceList(tokens, i + 1)
            if not nested then
                return nil, nextIndex
            end
            inner[#inner + 1] = { braceGroup = nested }
            i = nextIndex
            commandStart = false
        elseif type(tok) == "string" and tok == "}" and commandStart then
            local last = inner[#inner]
            if not last then
                return nil, "empty { } list"
            end
            if last ~= ";" and last ~= "&" then
                return nil, "missing ';' before '}'"
            end
            return inner, i + 1
        elseif type(tok) == "string" and
            (tok == ";" or tok == "&" or tok == "&&" or tok == "||" or tok == "|") then
            if commandStart then
                return nil, "unexpected '" .. tok .. "'"
            end
            inner[#inner + 1] = tok
            commandStart = true
            i = i + 1
        else
            inner[#inner + 1] = tok
            commandStart = false
            i = i + 1
        end
    end

    return nil, "missing '}'"
end

function text.internal.braceGroups(tokens)
    checkArg(1, tokens, "table")

    local out = {}
    local i
    i = 1
    local n = #tokens
    local commandStart = true

    while i <= n do
        local tok = tokens[i]

        if type(tok) == "string" and tok == "{" and commandStart then
            local inner, nextIndex = parseBraceList(tokens, i + 1)
            if not inner then
                return nil, nextIndex
            end
            out[#out + 1] = { braceGroup = inner }
            commandStart = false
            i = nextIndex
        elseif type(tok) == "string" and tok == "}" and commandStart then
            return nil, "unexpected '}'"
        elseif type(tok) == "string" and
            (tok == ";" or tok == "&" or tok == "&&" or tok == "||" or tok == "|") then
            if commandStart then
                return nil, "unexpected '" .. tok .. "'"
            end
            out[#out + 1] = tok
            commandStart = true
            i = i + 1
        else
            out[#out + 1] = tok
            commandStart = false
            i = i + 1
        end
    end

    return out
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
