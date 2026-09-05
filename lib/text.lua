-- Ported from openOS and I stripped out streams as I have no use for them.
-- Also I added &N> support

local unicode = require("unicode")
local tx = require("transforms")

local text = {}
text.internal = {}

-- Shell syntax
-- Added my own extras: Backgrounding and redirection

text.syntax = {
  "&%d+>>", -- &N>>
  "&%d+>",  -- &N>
  "&%d+<",  -- &N<
  "&&",     -- &&

  ">>",     -- >>
  ">",      -- >
  "<",      -- <

  "&",      -- background
  ";",      -- command separator
  "||",     -- ||
  "|"       -- |
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
    custom and table.concat(delimiters) or "<>|;&"
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

  local qr = nil

  quotes = quotes or {
    {"'", "'", true},
    {'"', '"'},
    {'`', '`'}
  }

  local function append(dst, txt, _qr)
    local size = #dst

    if size == 0 or dst[size].qr ~= _qr then
      dst[size + 1] = {
        txt = txt,
        qr = _qr
      }
    else
      dst[size].txt = dst[size].txt .. txt
    end
  end

  -- qr quot rules

  local tokens = {}
  local token = {}

  local escaped = false
  local start = -1

  for i = 1, unicode.len(input) do
    local char = unicode.sub(input, i, i)

    if escaped then
      escaped = false

      -- Escape handling
      if show_escapes or
         (qr and not qr[3] and qr[2] ~= char) then
        append(token, "\\", qr)
      end

      append(token, char, qr)

    elseif char == "\\" and (not qr or not qr[3]) then
      escaped = true

    elseif qr and qr[2] == char then
      -- End of quoted string
      if #token == 0 or #token[#token] == 0 then
        append(token, "", qr)
      end

      qr = nil

    elseif not qr and tx.first(quotes, function(Q)
      qr = Q[1] == char and Q or nil
      return qr
    end) then
      start = i

    elseif not qr and string.find(char, "%s") then
      if #token > 0 then
        table.insert(tokens, token)
      end

      token = {}

    else
      append(token, char, qr)
    end
  end

  if qr then
    return nil, "unclosed quote at index " .. start
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

  local result = {input}

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
      or {sub}

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

  for _, word in ipairs(words) do
    local norm = {}

    for _, part in ipairs(word) do
      norm = tx.concat(
        norm,
        not omitQuotes and part.qr
          and {part.qr[1], part.txt, part.qr[2]}
          or {part.txt}
      )
    end

    norms[#norms + 1] = table.concat(norm)
  end

  return norms
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