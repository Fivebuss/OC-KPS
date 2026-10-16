-- /bin/printf.lua
-- Oh boy. Printf. Time to copy MShell again
-- Normally a builtin but look how big this guy is I moved it out
local unicode = require("unicode")

local function utf8Char(code) -- How tf did I get to where im doing math for letters
    code = math.floor(tonumber(code) or 0)
    if code < 0 then return "" end
    if unicode and unicode.char then
        local ok, res = pcall(unicode.char, code)
        if ok and res then return res end
    end
    if code <= 0x7F then
        return string.char(code)
    elseif code <= 0x7FF then
        return string.char(
            0xC0 + math.floor(code / 64),
            0x80 + (code % 64)
        )
    elseif code <= 0xFFFF then
        return string.char(
            0xE0 + math.floor(code / 4096),
            0x80 + (math.floor(code / 64) % 64),
            0x80 + (code % 64)
        )
    elseif code <= 0x10FFFF then
        return string.char(
            0xF0 + math.floor(code / 262144),
            0x80 + (math.floor(code / 4096) % 64),
            0x80 + (math.floor(code / 64) % 64),
            0x80 + (code % 64)
        )
    end
    return ""
end

-- Pattern time. No, I am not insane enough to come up with these. AI did.
local function uWLen(s)
    if unicode and unicode.wlen then return unicode.wlen(s) end
    if unicode and unicode.len then return unicode.len(s) end
    return #s
end

local function uSub(s, i, j)
    if unicode and unicode.sub then return unicode.sub(s, i, j) end
    local t = {}
    for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do t[#t + 1] = c end
    j = j or #t
    local res = {}
    for idx = i, math.min(j, #t) do res[#res + 1] = t[idx] end
    return table.concat(res)
end

local function shellQuote(s)
    s = tostring(s == nil and "" or s)
    if s == "" then return "''" end
    if s:match("^[%w_%-%.%/%+=]+$") then return s end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function groupDigits(str)
    local intPart, decPart = str:match("^([^%.]+)(.*)$")
    intPart = intPart or str
    decPart = decPart or ""
    local k
    while true do
        intPart, k = intPart:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return intPart .. decPart
end

local function toBinary(n)
    n = math.floor(tonumber(n) or 0)
    if n == 0 then return "0" end
    local t = {}
    local isNeg = false
    if n < 0 then
        isNeg = true; n = math.abs(n)
    end
    while n > 0 do
        table.insert(t, 1, tostring(n % 2))
        n = math.floor(n / 2)
    end
    local res = table.concat(t)
    return isNeg and ("-" .. res) or res
end

local function expandBackslashes(str)
    local res = {}
    local idx = 1
    local slen = #str
    while idx <= slen do
        local c = str:sub(idx, idx)
        if c == "\\" then
            if idx == slen then return nil, "trailing backslash" end
            local nxt = str:sub(idx + 1, idx + 1)
            -- gross if else spam
            if nxt == "n" then
                res[#res + 1] = "\n"; idx = idx + 2
            elseif nxt == "r" then
                res[#res + 1] = "\r"; idx = idx + 2
            elseif nxt == "t" then
                res[#res + 1] = "\t"; idx = idx + 2
            elseif nxt == "b" then
                res[#res + 1] = "\b"; idx = idx + 2
            elseif nxt == "f" then
                res[#res + 1] = "\f"; idx = idx + 2
            elseif nxt == "v" then
                res[#res + 1] = "\v"; idx = idx + 2
            elseif nxt == "a" then
                res[#res + 1] = "\7"; idx = idx + 2
            elseif nxt == "\\" then
                res[#res + 1] = "\\"; idx = idx + 2
            elseif nxt == "0" then
                res[#res + 1] = "\0"; idx = idx + 2
            elseif nxt == "c" then
                return table.concat(res), "halt"
            elseif nxt == "x" then
                local hex = str:sub(idx + 2):match("^%x%x")
                if not hex then return nil, "invalid hex escape sequence" end
                local code = tonumber(hex, 16)
                res[#res + 1] = utf8Char(code)
                idx = idx + 2 + #hex
            elseif nxt == "u" and str:sub(idx + 2, idx + 2) == "{" then
                local hex, subLen = str:sub(idx + 3):match("^(%x+)%}()")
                if not hex then return nil, "invalid unicode escape sequence" end
                local code = tonumber(hex, 16)
                res[#res + 1] = utf8Char(code)
                idx = idx + 3 + subLen - 1
            else
                return nil, "unknown escape sequence '\\" .. nxt .. "'"
            end
        else
            res[#res + 1] = c
            idx = idx + 1
        end
    end
    return table.concat(res), nil
end

local rawTargets = args or {}
if #rawTargets == 0 then
    io.writelnError("printf: missing format string")
    os.exit(1)
    return
end

-- Strip quotes from arguments if passed directly from raw shell parsing layers
local printArgs = {}
local fmt = console.stripQuotes(rawTargets[1])
for k = 2, #rawTargets do
    printArgs[#printArgs + 1] = console.stripQuotes(rawTargets[k])
end

local argSeqIdx = 1
local totalArgs = #printArgs

local function getArg(pos)
    local idx = pos or argSeqIdx
    if not pos then argSeqIdx = argSeqIdx + 1 end
    if idx < 1 or idx > totalArgs then
        return nil, "missing argument"
    end
    return printArgs[idx], nil
end

local output = {}
local halted = false

repeat
    local startSeqIdx = argSeqIdx
    local i = 1
    local len = #fmt

    while i <= len do
        local c = fmt:sub(i, i)
        if c == "\\" then
            if i == len then
                io.writelnError("printf: trailing backslash in format string")
                os.exit(1)
                return
            end
            local nxt = fmt:sub(i + 1, i + 1)
            -- spam musubi
            if nxt == "n" then
                output[#output + 1] = "\n"; i = i + 2
            elseif nxt == "r" then
                output[#output + 1] = "\r"; i = i + 2
            elseif nxt == "t" then
                output[#output + 1] = "\t"; i = i + 2
            elseif nxt == "b" then
                output[#output + 1] = "\b"; i = i + 2
            elseif nxt == "f" then
                output[#output + 1] = "\f"; i = i + 2
            elseif nxt == "v" then
                output[#output + 1] = "\v"; i = i + 2
            elseif nxt == "a" then
                output[#output + 1] = "\7"; i = i + 2
            elseif nxt == "\\" then
                output[#output + 1] = "\\"; i = i + 2
            elseif nxt == "0" then
                output[#output + 1] = "\0"; i = i + 2
            elseif nxt == "c" then
                halted = true
                break
            elseif nxt == "x" then
                local hex = fmt:sub(i + 2):match("^%x%x")
                if not hex then
                    io.writelnError("printf: invalid hex escape sequence")
                    os.exit(1)
                    return
                end
                local code = tonumber(hex, 16)
                output[#output + 1] = utf8Char(code)
                i = i + 2 + #hex
            elseif nxt == "u" and fmt:sub(i + 2, i + 2) == "{" then
                local hex, subLen = fmt:sub(i + 3):match("^(%x+)%}()")
                if not hex then
                    io.writelnError("printf: invalid unicode escape sequence")
                    os.exit(1)
                    return
                end
                local code = tonumber(hex, 16)
                output[#output + 1] = utf8Char(code)
                i = i + 3 + subLen - 1
            else
                io.writelnError("printf: unknown escape sequence '\\" .. nxt .. "'")
                os.exit(1)
                return
            end
        elseif c == "%" then
            if fmt:sub(i + 1, i + 1) == "%" then
                output[#output + 1] = "%"
                i = i + 2
            else
                local pos1 = i + 1
                local valPos = nil
                local pNum, pLen = fmt:sub(pos1):match("^(%d+)%$()")
                if pNum then
                    valPos = tonumber(pNum)
                    pos1 = pos1 + pLen - 1
                end

                local flags = { hash = false, quote = false, plus = false, space = false, minus = false, zero = false }
                while pos1 <= len do
                    local fl = fmt:sub(pos1, pos1)
                    if fl == "#" then
                        flags.hash = true
                    elseif fl == "'" then
                        flags.quote = true
                    elseif fl == "+" then
                        flags.plus = true
                    elseif fl == " " then
                        flags.space = true
                    elseif fl == "-" then
                        flags.minus = true
                    elseif fl == "0" then
                        flags.zero = true
                    else
                        break
                    end
                    pos1 = pos1 + 1
                end

                local width = nil
                local wNum, wLen = fmt:sub(pos1):match("^(%d+)()")
                if wNum then
                    width = tonumber(wNum)
                    pos1 = pos1 + wLen - 1
                elseif fmt:sub(pos1, pos1) == "*" then
                    pos1 = pos1 + 1
                    local wPosNum, wPosLen = fmt:sub(pos1):match("^(%d+)%$()")
                    local wArgPos = wPosNum and tonumber(wPosNum) or nil
                    if wPosNum then pos1 = pos1 + wPosLen - 1 end
                    local wVal, err = getArg(wArgPos)
                    if err then
                        io.writelnError("printf: " .. err)
                        os.exit(1)
                        return
                    end
                    local wNumVal = tonumber(wVal) or 0
                    if wNumVal < 0 then
                        flags.minus = true
                        width = math.abs(wNumVal)
                    else
                        width = wNumVal
                    end
                end

                local precision = nil
                if fmt:sub(pos1, pos1) == "." then
                    pos1 = pos1 + 1
                    local prNum, prLen = fmt:sub(pos1):match("^(%d+)()")
                    if prNum then
                        precision = tonumber(prNum)
                        pos1 = pos1 + prLen - 1
                    elseif fmt:sub(pos1, pos1) == "*" then
                        pos1 = pos1 + 1
                        local prPosNum, prPosLen = fmt:sub(pos1):match("^(%d+)%$()")
                        local prArgPos = prPosNum and tonumber(prPosNum) or nil
                        if prPosNum then pos1 = pos1 + prPosLen - 1 end
                        local prVal, err = getArg(prArgPos)
                        if err then
                            io.writelnError("printf: " .. err)
                            os.exit(1)
                            return
                        end
                        local prNumVal = tonumber(prVal)
                        if prNumVal and prNumVal >= 0 then
                            precision = prNumVal
                        end
                    else
                        precision = 0
                    end
                end

                if pos1 > len then
                    io.writelnError("printf: incomplete format specifier")
                    os.exit(1)
                    return
                end

                local typeChar = fmt:sub(pos1, pos1)
                pos1 = pos1 + 1
                i = pos1

                local rawVal, err = getArg(valPos)
                if err then
                    io.writelnError("printf: " .. err)
                    os.exit(1)
                    return
                end

                local formattedStr = ""

                if typeChar == "s" then
                    local str = tostring(rawVal == nil and "nil" or rawVal)
                    if precision then
                        str = uSub(str, 1, precision)
                    end
                    formattedStr = str
                elseif typeChar == "q" then
                    formattedStr = shellQuote(rawVal)
                elseif typeChar == "c" then
                    local num = tonumber(rawVal)
                    if num then
                        formattedStr = utf8Char(num)
                    else
                        formattedStr = uSub(tostring(rawVal or ""), 1, 1)
                    end
                elseif typeChar == "b" then
                    local num = tonumber(rawVal)
                    if num then
                        if num % 1 ~= 0 then
                            io.writelnError("printf: expected integer, got float")
                            os.exit(1)
                            return
                        end
                        formattedStr = (flags.hash and "0b" or "") .. toBinary(num)
                    else
                        local expanded, expErr = expandBackslashes(tostring(rawVal or ""))
                        if expErr and expErr ~= "halt" then
                            io.writelnError("printf: " .. expErr)
                            os.exit(1)
                            return
                        end
                        formattedStr = expanded or ""
                    end
                elseif typeChar:match("^[diuoxX]$") then
                    local num = tonumber(rawVal)
                    if not num or num % 1 ~= 0 then
                        io.writelnError("printf: expected integer, got '" .. tostring(rawVal) .. "'")
                        os.exit(1)
                        return
                    end
                    if typeChar == "d" or typeChar == "i" then
                        local sign = ""
                        if num >= 0 then
                            if flags.plus then
                                sign = "+"
                            elseif flags.space then
                                sign = " "
                            end
                        end
                        formattedStr = sign .. string.format("%.0f", num)
                    elseif typeChar == "u" then
                        formattedStr = string.format("%.0f", math.abs(num))
                    elseif typeChar == "o" then
                        formattedStr = (flags.hash and num ~= 0 and "0o" or "") .. string.format("%o", num)
                    elseif typeChar == "x" then
                        formattedStr = (flags.hash and "0x" or "") .. string.format("%x", num)
                    elseif typeChar == "X" then
                        formattedStr = (flags.hash and "0X" or "") .. string.format("%X", num)
                    end
                    if flags.quote then
                        formattedStr = groupDigits(formattedStr)
                    end
                elseif typeChar:match("^[feEgG]$") then
                    local num = tonumber(rawVal) or 0
                    local fmtSpec = "%" ..
                        (flags.plus and "+" or (flags.space and " " or "")) ..
                        (precision and ("." .. precision) or "") .. typeChar
                    formattedStr = string.format(fmtSpec, num)
                    if flags.quote then
                        formattedStr = groupDigits(formattedStr)
                    end
                elseif typeChar == "p" then
                    formattedStr = string.format("%p", rawVal) or tostring(rawVal)
                else
                    io.writelnError("printf: unknown conversion specifier '%" .. typeChar .. "'")
                    os.exit(1)
                    return
                end

                local displayWidth = uWLen(formattedStr)
                if width and width > displayWidth then
                    local padLen = width - displayWidth
                    if flags.minus then
                        formattedStr = formattedStr .. string.rep(" ", padLen)
                    elseif flags.zero and typeChar:match("^[diuoxXbfeEgG]$") then
                        local signPrefix = formattedStr:match("^[%+%- %0x0X0o0b]+") or ""
                        local rest = formattedStr:sub(#signPrefix + 1)
                        formattedStr = signPrefix .. string.rep("0", padLen) .. rest
                    else
                        formattedStr = string.rep(" ", padLen) .. formattedStr
                    end
                end

                output[#output + 1] = formattedStr
            end
        else
            output[#output + 1] = c
            i = i + 1
        end
    end

    if halted then break end
    if totalArgs == 0 then break end
    if argSeqIdx <= startSeqIdx then break end
until argSeqIdx > totalArgs

io.write(table.concat(output))
os.exit(0)