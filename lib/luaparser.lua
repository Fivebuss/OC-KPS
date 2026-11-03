--[=[===========================================================
--=
--=  Dumb Lua Parser - Lua parsing library (NekOware fork, stripped)
--=  by Marcus 'ReFreezed' Thunström
--=
--=  Further stripped by fivebuss of ALOT of things I wont use
--=
--=  License: MIT (see the bottom of this file)
--=
--============================================================]=]

local NORMALIZE_MINUS_ZERO, HANDLE_ENV -- Should HANDLE_ENV be a setting?
do
	local n              = 0
	NORMALIZE_MINUS_ZERO = tostring(-n) == "0" -- Lua 5.3+ normalizes -0 to 0.
end
do
	local pcall = pcall
	local _ENV  = nil
	---@diagnostic disable-next-line: global-in-nil-env
	HANDLE_ENV  = not pcall(function() return _G end) -- Looking up the global _G will raise an error if _ENV is supported (Lua 5.2+).
end
local assert      = assert
local error       = error
local ipairs      = ipairs
local loadstring  = loadstring or load
local pairs       = pairs
local tonumber    = tonumber
local tostring    = tostring
local type        = type
local jit         = jit
local mathFloor   = math.floor
local mathMax     = math.max
local mathMin     = math.min
local mathType    = math.type -- May be nil.

local F           = string.format
local stringByte  = string.byte
local stringChar  = string.char
local stringFind  = string.find
local stringGsub  = string.gsub
local stringMatch = string.match
local stringRep   = string.rep
local stringSub   = string.sub

local tableConcat = table.concat
local tableInsert = table.insert
local tableUnpack = table.unpack or unpack
local tableSort   = table.sort
local function newSet(values)
	local set = {}
	for _, v in ipairs(values) do
		set[v] = true
	end
	return set
end
local function newCharSet(chars)
	return newSet { stringByte(chars, 1, #chars) }
end

local KEYWORDS            = newSet {
	"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if",
	"in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}
local OPERATORS_UNARY     = newSet {
	"-", "not", "#", "~",
}
local OPERATORS_BINARY    = newSet {
	"+", "-", "*", "/", "//", "^", "%",
	"&", "~", "|", ">>", "<<", "..",
	"<", "<=", ">", ">=", "==", "~=",
	"and", "or",
}
local OPERATOR_PRECEDENCE = {
	["or"] = 1,
	["and"] = 2,
	["<"] = 3,
	[">"] = 3,
	["<="] = 3,
	[">="] = 3,
	["~="] = 3,
	["=="] = 3,
	["|"] = 4,
	["~"] = 5,
	["&"] = 6,
	["<<"] = 7,
	[">>"] = 7,
	[".."] = 8,
	["+"] = 9,
	["-"] = 9,
	["*"] = 10,
	["/"] = 10,
	["//"] = 10,
	["%"] = 10,
	unary = 11, -- "-", "not", "#", "~"
	["^"] = 12,
}


local TOKEN_BYTES         = {
	NAME_START      = newCharSet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_",
	DASH            = newCharSet "-",
	NUM             = newCharSet "0123456789",
	QUOTE           = newCharSet "\"'",
	SQUARE          = newCharSet "[",
	DOT             = newCharSet ".",
	PUNCT_TWO_CHARS = newCharSet ".=~<>:/<>",
	PUNCT_ONE_CHAR  = newCharSet "+-*/%^#<>=(){}[];:,.&~|",
}

local NUMERAL_PATTERNS    = {
	HEX_FRAC_EXP = stringGsub("^( 0[Xx] (%x*) %.(%x+) [Pp]([-+]?%x+) )", " +", ""),
	HEX_FRAC     = stringGsub("^( 0[Xx] (%x*) %.(%x+)                )", " +", ""),
	HEX_EXP      = stringGsub("^( 0[Xx] (%x+) %.?     [Pp]([-+]?%x+) )", " +", ""),
	HEX          = stringGsub("^( 0[Xx]  %x+  %.?                    )", " +", ""),
	BIN          = stringGsub("^( 0[Bb]  [01]+                       )", " +", ""),
	DEC_FRAC_EXP = stringGsub("^(        %d*  %.%d+   [Ee][-+]?%d+   )", " +", ""),
	DEC_FRAC     = stringGsub("^(        %d*  %.%d+                  )", " +", ""),
	DEC_EXP      = stringGsub("^(        %d+  %.?     [Ee][-+]?%d+   )", " +", ""),
	DEC          = stringGsub("^(        %d+  %.?                    )", " +", ""),
}



-- :NodeFields

local NODE_PARENT    = 1
local NODE_CONTAINER = 2
local NODE_KEY       = 3
local NODE_TOKEN     = 4

local TOKEN_SOURCEPATH    = 1
local TOKEN_LINESTART     = 2
local TOKEN_LINEEND       = 3
local TOKEN_POSITIONSTART = 4
local TOKEN_POSITIONEND   = 5

local function populateCommonNodeFields(token, node)
	-- All nodes have these fields.
	node.sourcePath   = token and token[TOKEN_SOURCEPATH] or "?"

	node[NODE_TOKEN] = token
	node.line         = token and token[TOKEN_LINESTART] or 0
	node.position     = token and token[TOKEN_POSITIONSTART] or 0

	-- These fields are set by updateReferences():
	-- node.parent    = nil -- Refers to the node's parent in the tree.
	-- node.container = nil -- Refers to the specific table that the node is in, which could be the parent itself or a field in the parent.
	-- node.key       = nil -- Refers to the specific field in the container that the node is in (which is either a string or an integer).

	-- toLua() uses these fields if present:
	-- node.pretty = bool
	-- node.prefix = luaString
	-- node.suffix = luaString

	return node
end

-- AST expressions.
local function AstIdentifier(token, name)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type        = "identifier",
		name        = name, -- String.
		attribute   = "", -- "" | "close" | "const"  -- Only used in declarations.
		declaration = false, -- AstIdentifier (whose parent is an AstDeclaration, AstFunction or AstFor). Updated by updateReferences(). This is nil for globals.
		sourcePath  = "",
		line        = 0,
		position    = 0,
	})
end
local function AstVararg(token)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type        = "vararg",
		declaration = false, -- AstVararg (whose parent is an AstFunction). Updated by updateReferences(). This is nil in the main chunk (or in a non-vararg function, which is probably an error).
		adjustToOne = false, -- True if parentheses surround the vararg.
		sourcePath  = "",
		line        = 0,
		position    = 0,
	})
end
local function AstLiteral(token, v)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "literal",
		value      = v, -- Number, string, boolean or nil.
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end
local function AstTable(token)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "table",
		fields     = {}, -- Array of {key=expression, value=expression, generatedKey=bool}. generatedKey is true for implicit keys (i.e. {x,y}) and false for explicit keys (i.e. {a=x,b=y}). Note that the state of generatedKey affects the output of toLua()! 'key' may be nil if generatedKey is true.
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end
local function AstLookup(token)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "lookup",
		object     = false, -- Expression.
		member     = false, -- Expression.
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end
local function AstUnary(token, op)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "unary",
		operator   = op, -- "-" | "not" | "#" | "~"
		expression = false, -- Expression.
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end
local function AstBinary(token, op)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "binary",
		operator   = op, -- "+" | "-" | "*" | "/" | "//" | "^" | "%" | "&" | "~" | "|" | ">>" | "<<" | ".." | "<" | "<=" | ">" | ">=" | "==" | "~=" | "and" | "or"
		left       = false, -- Expression.
		right      = false, -- Expression.
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end
local function AstCall(token)
	return populateCommonNodeFields(token, { -- Calls can be both expressions and statements.
		false, false, false, false,
		type        = "call",
		callee      = false,              -- Expression.
		arguments   = {},                 -- Array of expressions.
		method      = false,              -- True if the call is a method call. Method calls must have a callee that is a lookup with a member expression that is a string literal that can pass as an identifier.
		adjustToOne = false,              -- True if parentheses surround the call.
		sourcePath  = "",
		line        = 0,
		position    = 0,
	})
end
local function AstFunction(token)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "function",
		parameters = {}, -- Array of AstIdentifier and maybe an AstVararg at the end.
		body       = false, -- AstBlock.
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end

-- AST statements.
local function AstBreak(token)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "break",
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end
local function AstReturn(token)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "return",
		values     = {}, -- Array of expressions.
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end
local function AstLabel(token, name)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "label",
		name       = name, -- String. The value must be able to pass as an identifier.
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end
local function AstGoto(token, name)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "goto",
		name       = name, -- String. The value must be able to pass as an identifier.
		label      = false, -- AstLabel. Updated by updateReferences().
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end
local function AstBlock(token)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "block",
		statements = {}, -- Array of statements.
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end
local function AstDeclaration(token)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "declaration",
		names      = {}, -- Array of AstIdentifier.
		values     = {}, -- Array of expressions.
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end
local function AstAssignment(token)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "assignment",
		targets    = {}, -- Mixed array of AstIdentifier and AstLookup.
		values     = {}, -- Array of expressions.
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end
local function AstIf(token)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "if",
		condition  = false, -- Expression.
		bodyTrue   = false, -- AstBlock.
		bodyFalse  = false, -- AstBlock or nil.
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end
local function AstWhile(token)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "while",
		condition  = false, -- Expression.
		body       = false, -- AstBlock.
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end
local function AstRepeat(token)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "repeat",
		body       = false, -- AstBlock.
		condition  = false, -- Expression.
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end
local function AstFor(token, kind)
	return populateCommonNodeFields(token, {
		false, false, false, false,
		type       = "for",
		kind       = kind, -- "numeric" | "generic"
		names      = {}, -- Array of AstIdentifier.
		values     = {}, -- Array of expressions.
		body       = false, -- AstBlock.
		sourcePath = "",
		line       = 0,
		position   = 0,
	})
end

local function Stats()
	return {
		-- minify():
		renameCount        = 0,
		generatedNameCount = 0,
	}
end
-- count = countString( haystack, needle [, plain=false ] )
local function countString(haystack, needle, plain)
	local count = 0
	local pos   = 1

	while true do
		local _, i2 = stringFind(haystack, needle, pos, plain)
		if not i2 then return count end

		count = count + 1
		pos   = i2 + 1
	end
end

-- count = countSubString( haystack, startPosition, endPosition, needle [, plain=false ] )
local function countSubString(haystack, pos, posEnd, needle, plain)
	local count = 0

	while true do
		local _, i2 = stringFind(haystack, needle, pos, plain)
		if not i2 or i2 > posEnd then return count end

		count = count + 1
		pos   = i2 + 1
	end
end



-- errorf( [ level=1, ] format, ... )
local function errorf(level, s, ...)
	if type(level) == "number" then
		error(F(s, ...), (level == 0 and 0 or (1 + level)))
	else
		error(F(level, s, ...), 2)
	end
end

-- assertArg1( functionName, argumentNumber, value, expectedType                 [, level=2 ] )
-- assertArg2( functionName, argumentNumber, value, expectedType1, expectedType2 [, level=2 ] )
local function assertArg1(funcName, argNum, v, expectedType, level)
	if type(v) == expectedType then return end
	errorf(1 + (level or 2), "Bad argument #%d to '%s'. (Expected %s, got %s)", argNum, funcName, expectedType, type(v))
end
local function assertArg2(funcName, argNum, v, expectedType1, expectedType2, level)
	if type(v) == expectedType1 or type(v) == expectedType2 then return end
	errorf(1 + (level or 2), "Bad argument #%d to '%s'. (Expected %s or %s, got %s)", argNum, funcName, expectedType1,
		expectedType2, type(v))
end
local function getLineNumber(s, pos)
	return 1 + countSubString(s, 1, pos - 1, "\n", true)
end
local formatMessageInFile
do
	local function findStartOfLine(s, pos, canBeEmpty)
		while pos > 1 do
			if stringByte(s, pos - 1) == 10 --[[\n]] and (canBeEmpty or stringByte(s, pos) ~= 10 --[[\n]]) then break end
			pos = pos - 1
		end
		return mathMax(pos, 1)
	end
	local function findEndOfLine(s, pos)
		while pos < #s do
			if stringByte(s, pos + 1) == 10 --[[\n]] then break end
			pos = pos + 1
		end
		return mathMin(pos, #s)
	end

	local function getSubTextLength(s, pos, posEnd)
		local len = 0

		while pos <= posEnd do
			if stringByte(s, pos) == 9 then -- '\t'
				len = len + 4
				pos = pos + 1
			else
				local _, i2 = stringFind(s, "^[%z\1-\127\194-\253][\128-\191]*", pos)
				if i2 and i2 <= posEnd then
					len = len + 1
					pos = i2 + 1
				else
					len = len + 1
					pos = pos + 1
				end
			end
		end

		return len
	end

	--[[local]]
	function formatMessageInFile(prefix, contents, path, pos, agent, s, ...)
		if agent ~= "" then
			agent = "[" .. agent .. "] "
		end

		s = F(s, ...)

		if contents == "" then
			return F("%s @ %s: %s%s", prefix, path, agent, s)
		end

		pos                 = mathMin(mathMax(pos, 1), #contents + 1)
		local ln            = getLineNumber(contents, pos)

		local lineStart     = findStartOfLine(contents, pos, true)
		local lineEnd       = findEndOfLine(contents, pos - 1)
		local linePre1Start = findStartOfLine(contents, lineStart - 1, false)
		local linePre1End   = findEndOfLine(contents, linePre1Start - 1)
		local linePre2Start = findStartOfLine(contents, linePre1Start - 1, false)
		local linePre2End   = findEndOfLine(contents, linePre2Start - 1)
		-- print(F("pos %d | lines %d..%d, %d..%d, %d..%d", pos, linePre2Start,linePre2End+1, linePre1Start,linePre1End+1, lineStart,lineEnd+1)) -- DEBUG

		return F("%s @ %s:%d: %s%s\n>\n%s%s%s>-%s^",
			prefix, path, ln, agent, s,
			(linePre2Start < linePre1Start and linePre2Start <= linePre2End) and
			F("> %s\n", (stringGsub(stringSub(contents, linePre2Start, linePre2End), "\t", "    "))) or "",
			(linePre1Start < lineStart and linePre1Start <= linePre1End) and
			F("> %s\n", (stringGsub(stringSub(contents, linePre1Start, linePre1End), "\t", "    "))) or "",
			(lineStart <= lineEnd) and
			F("> %s\n", (stringGsub(stringSub(contents, lineStart, lineEnd), "\t", "    "))) or ">\n",
			stringRep("-", getSubTextLength(contents, lineStart, pos - 1))
		)
	end
end

local function formatMessageAtToken(prefix, token, agent, s, ...)
	return (formatMessageInFile(prefix, (token and token.sourceString or ""), (token and token[TOKEN_SOURCEPATH] or "?"), (token and token[TOKEN_POSITIONSTART] or 0), agent, s, ...))
end
local function formatMessageAfterToken(prefix, token, agent, s, ...)
	return (formatMessageInFile(prefix, (token and token.sourceString or ""), (token and token[TOKEN_SOURCEPATH] or "?"), (token and token[TOKEN_POSITIONEND] + 1 or 0), agent, s, ...))
end

local function formatMessageAtNode(prefix, node, agent, s, ...)
	return (formatMessageInFile(prefix, node.sourceString or "", node.sourcePath, node.position, agent, s, ...))
end

local function formatErrorInFile(...) return formatMessageInFile("Error", ...) end
local function formatErrorAtToken(...) return formatMessageAtToken("Error", ...) end
local function formatErrorAfterToken(...) return formatMessageAfterToken("Error", ...) end
local function formatErrorAtNode(...) return formatMessageAtNode("Error", ...) end
local function iprev(t, i)
	i       = i - 1
	local v = t[i]

	if v ~= nil then return i, v end
end

local function ipairsr(t)
	return iprev, t, #t + 1
end



-- index = indexOf( array, value [, startIndex=1, endIndex=#array ] )
local function indexOf(t, v, i1, i2)
	for i = (i1 or 1), (i2 or #t) do
		if t[i] == v then return i end
	end
	return nil
end
local function lastItemWith1(t, k, v)
	for i, item in ipairsr(t) do
		if item[k] == v then return item, i end
	end
	return nil
end



-- text = getRelativeLocationText( sourcePathOfInterest, lineNumberOfInterest, otherSourcePath, otherLineNumber )
-- text = getRelativeLocationText( lineNumberOfInterest, otherLineNumber )
local function getRelativeLocationText(sourcePath, ln, otherSourcePath, otherLn)
	if type(sourcePath) ~= "string" then
		sourcePath, ln, otherSourcePath, otherLn = "", sourcePath, "", ln
	end

	if not (ln > 0) then
		return "at <UnknownLocation>"
	end

	if sourcePath ~= otherSourcePath then return F("at %s:%d", sourcePath, ln) end
	if ln + 1 == otherLn and otherLn > 0 then return F("on the previous line") end
	if ln - 1 == otherLn and otherLn > 0 then return F("on the next line") end
	if ln ~= otherLn then return F("on line %d", ln) end
	return "on the same line"
end

-- text = getRelativeLocationTextForToken( tokens, tokenOfInterest, otherToken )
local function getRelativeLocationTextForToken(tokens, tokOfInterest, otherTok)
	return getRelativeLocationText((tokens[tokOfInterest] and tokens[tokOfInterest][TOKEN_LINESTART] or 0),
		(tokens[otherTok] and tokens[otherTok][TOKEN_LINESTART] or 0))
end
local function formatNumber(n)
	-- @Speed: Cache!

	-- 64-bit int in LuaJIT (is what we assume, anyway).
	if jit and type(n) == "cdata" then
		local nStr = tostring(n)

		if stringFind(nStr, "i$") then
			if stringFind(nStr, "^0[-+]") then
				nStr = stringGsub(nStr, "^0%+?", "")
			else
				--
				-- LuaJIT doesn't seem to be able to parse nStr if we output it as-is.
				-- What is even the notation for complex numbers with a non-zero real part?
				-- Oh LuaJIT, you're so mysterious...
				--
				-- @Robustness: Make sure we don't choke when trying to simplify() complex numbers.
				--
				errorf(2, "Cannot output complex number '%s'.", nStr)
			end
		end

		return nStr
	end

	-- Int (including 64-bit ints in Lua 5.3+, and excluding whole floats).
	if n == mathFloor(n) and not (mathType and mathType(n) == "float") then
		local nStr = F("%.0f", n)
		if tonumber(nStr) == n then return nStr end
	end

	-- Anything else.
	return (tostring(n)
		:gsub("(e[-+])0+(%d+)$", "%1%2") -- Remove unnecessary zeroes after 'e'.
		:gsub("e%+", "e")          -- Remove plus after 'e'.
	)
end
local tokenize
do
	local ERROR_UNFINISHED_VALUE = {}

	-- Constant quote-stop patterns for the quoted-string branch (were built with string
	-- concatenation inside the tokenizer loop - pure per-token garbage).
	-- Character classes: { quote, backslash, newline }.
	local PAT_STRING_STOP_DOUBLE = "[\"\\\n]"
	local PAT_STRING_STOP_SINGLE = "['\\\n]"

	-- success, equalSignCountIfLong|errorCode, ptr = parseStringlikeToken( s, ptr )
	local function parseStringlikeToken(s, ptr)
		local longEqualSigns       = stringMatch(s, "^%[(=*)%[", ptr)
		local equalSignCountIfLong = longEqualSigns and #longEqualSigns

		-- Single line (comment).
		if not equalSignCountIfLong then
			local i1, i2 = stringFind(s, "\n", ptr)
			ptr          = i2 and i2 + 1 or #s + 1

			-- Multiline.
		else
			ptr = ptr + 1 + #longEqualSigns + 1

			local i1, i2 = stringFind(s, "%]" .. longEqualSigns .. "%]", ptr)
			if not i1 then
				return false, ERROR_UNFINISHED_VALUE, 0
			end

			ptr = i2 + 1
		end

		return true, equalSignCountIfLong, ptr
	end

	local function codepointToString(cp, buffer)
		if cp < 0 or cp > 0x10ffff then
			-- This error is actually incorrect as Lua supports codepoints up to 2^31.
			-- This is probably an issue that no one will ever encounter!
			return false, F("Codepoint 0x%X (%.0f) is outside the valid range (0..10FFFF).", cp, cp)
		end

		if cp < 128 then
			tableInsert(buffer, stringChar(cp))
			return true
		end

		local suffix = cp % 64
		local c4     = 128 + suffix
		cp           = (cp - suffix) / 64

		if cp < 32 then
			tableInsert(buffer, stringChar(192 + cp))
			tableInsert(buffer, stringChar(c4))
			return true
		end

		suffix   = cp % 64
		local c3 = 128 + suffix
		cp       = (cp - suffix) / 64

		if cp < 16 then
			tableInsert(buffer, stringChar(224 + cp))
			tableInsert(buffer, stringChar(c3))
			tableInsert(buffer, stringChar(c4))
			return true
		end

		suffix = cp % 64
		cp     = (cp - suffix) / 64

		tableInsert(buffer, stringChar(240 + cp))
		tableInsert(buffer, stringChar(128 + suffix))
		tableInsert(buffer, stringChar(c3))
		tableInsert(buffer, stringChar(c4))
		return true
	end

	local function parseStringContents(s, path, ptrStart, ptrEnd)
		local ptr    = ptrStart
		local buffer = {}

		while ptr <= ptrEnd do
			local i1 = stringFind(s, "\\", ptr, true)
			if not i1 or i1 > ptrEnd then break end

			if i1 > ptr then
				tableInsert(buffer, stringSub(s, ptr, i1 - 1))
			end
			ptr = i1 + 1

			-- local b1, b2, b3 = stringByte(s, ptr, ptr+2)

			if stringFind(s, "^a", ptr) then
				tableInsert(buffer, "\a"); ptr = ptr + 1
			elseif stringFind(s, "^b", ptr) then
				tableInsert(buffer, "\b"); ptr = ptr + 1
			elseif stringFind(s, "^t", ptr) then
				tableInsert(buffer, "\t"); ptr = ptr + 1
			elseif stringFind(s, "^n", ptr) then
				tableInsert(buffer, "\n"); ptr = ptr + 1
			elseif stringFind(s, "^v", ptr) then
				tableInsert(buffer, "\v"); ptr = ptr + 1
			elseif stringFind(s, "^f", ptr) then
				tableInsert(buffer, "\f"); ptr = ptr + 1
			elseif stringFind(s, "^r", ptr) then
				tableInsert(buffer, "\r"); ptr = ptr + 1
			elseif stringFind(s, "^\\", ptr) then
				tableInsert(buffer, "\\"); ptr = ptr + 1
			elseif stringFind(s, '^"', ptr) then
				tableInsert(buffer, "\""); ptr = ptr + 1
			elseif stringFind(s, "^'", ptr) then
				tableInsert(buffer, "\'"); ptr = ptr + 1
			elseif stringFind(s, "^\n", ptr) then
				tableInsert(buffer, "\n"); ptr = ptr + 1
			elseif stringFind(s, "^z", ptr) then
				local i1, i2 = stringFind(s, "^%s*", ptr + 1)
				ptr          = i2 + 1
			elseif stringFind(s, "^%d", ptr) then
				local nStr = stringMatch(s, "^%d%d?%d?", ptr)
				local byte = tonumber(nStr)

				if byte > 255 then
					return nil, formatErrorInFile(
						s, path, ptr, "Tokenizer",
						"Byte value '%s' is out-of-range in decimal escape sequence. (String starting %s)",
						nStr, getRelativeLocationText(getLineNumber(s, ptrStart), getLineNumber(s, ptr))
					)
				end

				tableInsert(buffer, stringChar(byte))
				ptr = ptr + #nStr
			elseif stringFind(s, "^x%x%x", ptr) then
				local hexStr = stringSub(s, ptr + 1, ptr + 2)
				local byte   = tonumber(hexStr, 16)

				tableInsert(buffer, stringChar(byte))
				ptr = ptr + 3
			elseif stringFind(s, "^u{%x+}", ptr) then
				local hexStr  = stringMatch(s, "^%x+", ptr + 2)
				local cp      = tonumber(hexStr, 16)

				local ok, err = codepointToString(cp, buffer)
				if not ok then
					return nil, formatErrorInFile(
						s, path, ptr + 2, "Tokenizer",
						"%s (String starting %s)",
						err, getRelativeLocationText(getLineNumber(s, ptrStart), getLineNumber(s, ptr))
					)
				end

				ptr = ptr + 3 + #hexStr
			else
				return nil, formatErrorInFile(
					s, path, ptr - 1, "Tokenizer",
					"Invalid escape sequence. (String starting %s)",
					getRelativeLocationText(getLineNumber(s, ptrStart), getLineNumber(s, ptr))
				)
			end
		end

		if ptr <= ptrEnd then
			tableInsert(buffer, stringSub(s, ptr, ptrEnd))
		end

		return tableConcat(buffer)
	end

	-- tokens, error = tokenize( luaString [, keepWhitespaceTokens=false ] [, pathForErrorMessages="?" ] )
	--[[local]]
	function tokenize(s, keepWhitespaceTokens, path)
		assertArg1("tokenize", 1, s, "string")

		if type(keepWhitespaceTokens) == "string" then
			path                 = keepWhitespaceTokens
			keepWhitespaceTokens = false
		else
			assertArg2("tokenize", 2, keepWhitespaceTokens, "boolean", "nil")
			assertArg2("tokenize", 3, path, "string", "nil")
		end

		if stringFind(s, "\r", 1, true) then
			s = stringGsub(s, "\r\n?", "\n")
		end
		path                        = path or "?"

		local tokens                = {}
		local count                 = 0
		local ptr                   = 1
		local ln                    = 1

		local BYTES_NAME_START      = TOKEN_BYTES.NAME_START
		local BYTES_DASH            = TOKEN_BYTES.DASH
		local BYTES_NUM             = TOKEN_BYTES.NUM
		local BYTES_QUOTE           = TOKEN_BYTES.QUOTE
		local BYTES_SQUARE          = TOKEN_BYTES.SQUARE
		local BYTES_DOT             = TOKEN_BYTES.DOT
		local BYTES_PUNCT_TWO_CHARS = TOKEN_BYTES.PUNCT_TWO_CHARS
		local BYTES_PUNCT_ONE_CHAR  = TOKEN_BYTES.PUNCT_ONE_CHAR

		local NUM_HEX_FRAC_EXP      = NUMERAL_PATTERNS.HEX_FRAC_EXP
		local NUM_HEX_FRAC          = NUMERAL_PATTERNS.HEX_FRAC
		local NUM_HEX_EXP           = NUMERAL_PATTERNS.HEX_EXP
		local NUM_HEX               = NUMERAL_PATTERNS.HEX
		local NUM_BIN               = NUMERAL_PATTERNS.BIN
		local NUM_DEC_FRAC_EXP      = NUMERAL_PATTERNS.DEC_FRAC_EXP
		local NUM_DEC_FRAC          = NUMERAL_PATTERNS.DEC_FRAC
		local NUM_DEC_EXP           = NUMERAL_PATTERNS.DEC_EXP
		local NUM_DEC               = NUMERAL_PATTERNS.DEC

		while true do
			local i1, i2 = stringFind(s, "^[ \t\n]+", ptr)

			if i1 then
				if keepWhitespaceTokens then
					local lnStart = ln
					local tokRepr = stringSub(s, i1, i2)
					ln            = ln + countString(tokRepr, "\n", true)
					count         = count + 1

					tokens[count] = {
						path, lnStart, ln, i1, i2,
						type           = "whitespace",
						value          = tokRepr,

						sourceString   = s,
					}
				else
					ln = ln + countSubString(s, i1, i2, "\n", true)
				end

				ptr = i2 + 1
			end

			if ptr > #s then break end

			local ptrStart = ptr
			local lnStart  = ln
			local b1, b2   = stringByte(s, ptr, ptr + 1)
			local tokType, tokRepr, tokValue

			-- Identifier/keyword.
			if BYTES_NAME_START[b1] then
				local i1, i2, word = stringFind(s, "^(.[%w_]*)", ptr)
				ptr                = i2 + 1
				tokType            = KEYWORDS[word] and "keyword" or "identifier"
				tokRepr            = stringSub(s, ptrStart, ptr - 1)
				tokValue           = tokRepr

				-- Comment.
			elseif BYTES_DASH[b1] and BYTES_DASH[b2] then
				ptr = ptr + 2

				local ok, equalSignCountIfLong
				ok, equalSignCountIfLong, ptr = parseStringlikeToken(s, ptr)

				if not ok then
					local errCode = equalSignCountIfLong
					if errCode == ERROR_UNFINISHED_VALUE then
						return nil, formatErrorInFile(s, path, ptrStart, "Tokenizer", "Unfinished long comment.")
					else
						return nil, formatErrorInFile(s, path, ptrStart, "Tokenizer", "Invalid comment.")
					end
				end

				-- Check for nesting of [[...]] which is deprecated in Lua. Sigh...
				if equalSignCountIfLong and equalSignCountIfLong == 0 then
					local pos = stringFind(s, "[[", ptrStart + 4, true)
					if pos and pos < ptr then
						return nil,
							formatErrorInFile(s, path, pos, "Tokenizer",
								"Cannot have nested comments. (Comment starting %s)",
								getRelativeLocationText(lnStart, getLineNumber(s, pos)))
					end
				end

				-- RAM separates: Comment tokens are only materialized when keepWhitespaceTokens
				-- is set. They are never needed by the parser itself, and every comment would
				-- otherwise cost a token table plus two substring allocations. Line counting
				-- below still runs over the comment span, so relative line checks that depend
				-- on comment lines (such as the ambiguous '( call after newline') stay correct.
				if keepWhitespaceTokens then
					tokType  = "comment"
					tokRepr  = stringSub(s, ptrStart, ptr - 1)
					tokRepr  = equalSignCountIfLong and tokRepr or
						(stringFind(tokRepr, "\n$") and tokRepr or tokRepr .. "\n") -- Make sure there's a newline at the end of single-line comments. (It may be missing if we've reached EOF.)
					tokValue = equalSignCountIfLong and stringSub(tokRepr, 5 + equalSignCountIfLong, -3 -
						equalSignCountIfLong) or stringSub(tokRepr, 3, -2)
				else
					ln = ln + countSubString(s, ptrStart, ptr - 1, "\n", true)
				end

				-- Number.
			elseif BYTES_NUM[b1] or (BYTES_DOT[b1] and BYTES_NUM[b2]) then
				local pat, maybeInt, kind, i1, i2, numStr = NUM_HEX_FRAC_EXP, false, "lua52hex",
					stringFind(s, NUM_HEX_FRAC_EXP, ptr)
				if not i1 then
					pat, maybeInt, kind, i1, i2, numStr = NUM_HEX_FRAC, false, "lua52hex",
						stringFind(s, NUM_HEX_FRAC, ptr)
					if not i1 then
						pat, maybeInt, kind, i1, i2, numStr = NUM_HEX_EXP, false, "lua52hex",
							stringFind(s, NUM_HEX_EXP, ptr)
						if not i1 then
							pat, maybeInt, kind, i1, i2, numStr = NUM_HEX, true, "", stringFind(s, NUM_HEX, ptr)
							if not i1 then
								pat, maybeInt, kind, i1, i2, numStr = NUM_BIN, true, "binary",
									stringFind(s, NUM_BIN, ptr) -- LuaJIT supports these, so why not.
								if not i1 then
									pat, maybeInt, kind, i1, i2, numStr = NUM_DEC_FRAC_EXP, false, "",
										stringFind(s, NUM_DEC_FRAC_EXP, ptr)
									if not i1 then
										pat, maybeInt, kind, i1, i2, numStr = NUM_DEC_FRAC, false, "",
											stringFind(s, NUM_DEC_FRAC, ptr)
										if not i1 then
											pat, maybeInt, kind, i1, i2, numStr = NUM_DEC_EXP, false, "",
												stringFind(s, NUM_DEC_EXP, ptr)
											if not i1 then
												pat, maybeInt, kind, i1, i2, numStr = NUM_DEC, true, "",
													stringFind(s, NUM_DEC, ptr)
												if not numStr then
													return nil,
														formatErrorInFile(s, path, ptrStart, "Tokenizer",
															"Malformed number.")
												end
											end
										end
									end
								end
							end
						end
					end
				end

				local numStrFallback = numStr

				if jit then
					if stringFind(s, "^[Ii]", i2 + 1) then -- Imaginary part of complex number.
						numStr = stringSub(s, i1, i2 + 1)
						i2     = i2 + 1
					elseif not maybeInt or stringFind(numStr, ".", 1, true) then
						-- void
					elseif stringFind(s, "^[Uu][Ll][Ll]", i2 + 1) then -- Unsigned 64-bit integer.
						numStr = stringSub(s, i1, i2 + 3)
						i2     = i2 + 3
					elseif stringFind(s, "^[Ll][Ll]", i2 + 1) then -- Signed 64-bit integer.
						numStr = stringSub(s, i1, i2 + 2)
						i2     = i2 + 2
					end
				end

				local n = tonumber(numStr)

				if not n and jit then
					local chunk = loadstring("return " .. numStr)
					n           = chunk and chunk() or n
				end

				n = n or tonumber(numStrFallback)

				if not n then
					-- Note: We know we're not running LuaJIT here as it supports hexadecimal floats and binary notation, thus we use numStrFallback instead of numStr.

					-- Support hexadecimal floats if we're running Lua 5.1.
					if kind == "lua52hex" then
						local _, intStr, fracStr, expStr
						if pat == NUM_HEX_FRAC_EXP then
							_, intStr, fracStr, expStr = stringMatch(numStrFallback, NUM_HEX_FRAC_EXP)
						elseif pat == NUM_HEX_FRAC then
							_, intStr, fracStr = stringMatch(numStrFallback, NUM_HEX_FRAC); expStr = "0"
						elseif pat == NUM_HEX_EXP then
							_, intStr, expStr = stringMatch(numStrFallback, NUM_HEX_EXP); fracStr = ""
						else
							return nil,
								formatErrorInFile(s, path, ptrStart, "Tokenizer",
									"Internal error parsing the number '%s'.", numStrFallback)
						end

						n = tonumber(intStr, 16) or 0 -- intStr may be "".

						local fracValue = 1
						for i = 1, #fracStr do
							fracValue = fracValue / 16
							n         = n + tonumber(stringSub(fracStr, i, i), 16) * fracValue
						end

						n = n * 2 ^ stringGsub(expStr, "^+", "")
					elseif kind == "binary" then
						n = tonumber(stringSub(numStrFallback, 3), 2)
					end
				end

				if not n then
					return nil, formatErrorInFile(s, path, ptrStart, "Tokenizer", "Invalid number.")
				end

				ptr      = i2 + 1
				tokType  = "number"
				tokRepr  = numStr
				tokValue = n

				if stringFind(s, "^[%w_.]", ptr) then
					local after = stringMatch(s, "^%.?%d+", ptr) or stringMatch(s, "^[%w_.][%w_.]?", ptr)
					return nil,
						formatErrorInFile(s, path, ptrStart, "Tokenizer", "Malformed number near '%s%s'.", numStr, after)
				end

				-- Quoted string.
			elseif BYTES_QUOTE[b1] then
				local quoteByte = b1
				ptr             = ptr + 1

				local pat       = (quoteByte == 34) and PAT_STRING_STOP_DOUBLE or PAT_STRING_STOP_SINGLE

				while true do
					local i1 = stringFind(s, pat, ptr)
					if not i1 then
						return nil, formatErrorInFile(s, path, ptrStart, "Tokenizer", "Unfinished string.")
					end

					ptr          = i1
					local b1, b2 = stringByte(s, ptr, ptr + 1)

					-- '"'
					if b1 == quoteByte then
						ptr = ptr + 1
						break

						-- '\'
					elseif b1 == 92 then
						ptr = ptr + 1

						if b2 == 122 then -- 'z'
							ptr         = ptr + 1
							local _, i2 = stringFind(s, "^%s*", ptr)
							ptr         = i2 + 1
						else
							-- Note: We don't have to look for multiple characters after the escape, like \nnn - this algorithm works anyway.
							if ptr > #s then
								return nil, formatErrorInFile(
									s, path, ptr, "Tokenizer",
									"Unfinished string after escape character. (String starting %s)",
									getRelativeLocationText(lnStart, getLineNumber(s, ptr))
								)
							end
							ptr = ptr + 1 -- Just skip the next character, whatever it might be.
						end

						-- '\n'
					elseif b1 == 10 then
						-- Lua, this is silly!
						return nil,
							formatErrorInFile(s, path, ptr, "Tokenizer", "Unescaped newline in string (starting %s).",
								getRelativeLocationText(lnStart, getLineNumber(s, ptr)))
					else
						assert(false)
					end
				end

				tokType = "string"
				tokRepr = stringSub(s, ptrStart, ptr - 1)

				local chunk = loadstring("return " .. tokRepr, "@") -- Try to make Lua parse the string value before we fall back to our own parser which is probably slower.
				if chunk then
					tokValue = chunk()
					assert(type(tokValue) == "string")
				else
					local stringValue, err = parseStringContents(s, path, ptrStart + 1, ptr - 2)
					if not stringValue then return nil, err end
					tokValue = stringValue
				end

				-- Long string.
			elseif BYTES_SQUARE[b1] and stringFind(s, "^=*%[", ptr + 1) then
				local ok, equalSignCountIfLong
				ok, equalSignCountIfLong, ptr = parseStringlikeToken(s, ptr)

				if not ok then
					local errCode = equalSignCountIfLong
					if errCode == ERROR_UNFINISHED_VALUE then
						return nil, formatErrorInFile(s, path, ptrStart, "Tokenizer", "Unfinished long string.")
					else
						return nil, formatErrorInFile(s, path, ptrStart, "Tokenizer", "Invalid long string.")
					end
				end

				tokType = "string"
				tokRepr = stringSub(s, ptrStart, ptr - 1)

				local chunk, err = loadstring("return " .. tokRepr, "@")
				if not chunk then
					err = stringGsub(err, "^:%d+: ", "")
					return nil,
						formatErrorInFile(s, path, ptrStart, "Tokenizer",
							"Could not convert long string token to value. (%s)", err)
				end
				tokValue = assert(chunk)()
				assert(type(tokValue) == "string")

				-- Punctuation.
			elseif BYTES_DOT[b1] and stringFind(s, "^%.%.", ptr + 1) then
				ptr      = ptr + 3
				tokType  = "punctuation"
				tokRepr  = stringSub(s, ptrStart, ptr - 1)
				tokValue = tokRepr
			elseif BYTES_PUNCT_TWO_CHARS[b1] and stringFind(s, "^%.%.", ptr) or stringFind(s, "^[=~<>]=", ptr) or stringFind(s, "^::", ptr) or stringFind(s, "^//", ptr) or stringFind(s, "^<<", ptr) or stringFind(s, "^>>", ptr) then
				ptr      = ptr + 2
				tokType  = "punctuation"
				tokRepr  = stringSub(s, ptrStart, ptr - 1)
				tokValue = tokRepr
			elseif BYTES_PUNCT_ONE_CHAR[b1] then
				ptr      = ptr + 1
				tokType  = "punctuation"
				tokRepr  = stringSub(s, ptrStart, ptr - 1)
				tokValue = tokRepr
			else
				return nil, formatErrorInFile(s, path, ptrStart, "Tokenizer", "Unknown character.")
			end
				-- RAM analysis: If we skipped a comment (see above), there is no token to record.
				if tokType then
					ln            = ln + countString(tokRepr, "\n", true)
					count         = count + 1

					tokens[count] = {
						path, lnStart, ln, ptrStart, ptr - 1,
						type           = tokType,
						value          = tokValue,
					}

					-- print(F("%4d %-11s '%s'", count, tokType, (stringGsub(tokRepr, "\n", "\\n"))))
				end
			end

		return tokens
	end
end
local function isToken(token, tokType, tokValue)
	return token ~= nil and token.type == tokType and token.value == tokValue
end

local function isTokenType(token, tokType)
	return token ~= nil and token.type == tokType
end

local function isTokenAnyValue(token, tokValueSet)
	return token ~= nil and tokValueSet[token.value] == true
end



local function getLeftmostToken(node)
	if node.type == "binary" then
		return getLeftmostToken(node.left)
	else
		return node[NODE_TOKEN]
	end
end



local parseExpressionInternal, parseExpressionList, parseFunctionParametersAndBody, parseBlock

local function parseIdentifier(tokens, tok) --> ident, token, error
	if not isTokenType(tokens[tok], "identifier") then
		return nil, tok, formatErrorAtToken(tokens[tok], "Parser", "Expected an identifier.")
	end

	local ident = AstIdentifier(tokens[tok], tokens[tok].value)
	tok         = tok + 1

	return ident, tok
end

local function parseNameList(tokens, tok, names, allowVararg, allowAttributes) --> success, token, error|nil
	while true do
		if allowVararg and isToken(tokens[tok], "punctuation", "...") then
			local vararg = AstVararg(tokens[tok])
			tok          = tok + 1 -- '...'

			tableInsert(names, vararg)

			return true, tok
		end

		local ident, tokNext, err = parseIdentifier(tokens, tok)
		if not ident then return false, tok, err end
		tok = tokNext

		if allowAttributes and isToken(tokens[tok], "punctuation", "<") then
			tok = tok + 1 -- '<'

			local attrIdent, tokNext, err = parseIdentifier(tokens, tok)
			if not attrIdent then
				return false, tok, err
			elseif not (attrIdent.name == "close" or attrIdent.name == "const") then
				return false, tok,
					formatErrorAtToken(tokens[tok], "Parser", "Expected 'close' or 'const' for attribute name.")
			end
			tok = tokNext

			ident.attribute = attrIdent.name

			if not isToken(tokens[tok], "punctuation", ">") then
				return nil, tok, formatErrorAfterToken(tokens[tok - 1], "Parser", "Expected '>' after attribute name.")
			end
			tok = tok + 1 -- '>'
		end

		tableInsert(names, ident)

		if not isToken(tokens[tok], "punctuation", ",") then
			return true, tok
		end
		tok = tok + 1 -- ','
	end

	return true, tok
end

local function parseTable(tokens, tokStart) --> tableNode, token, error
	local tok            = tokStart
	local tableNode      = AstTable(tokens[tok])
	tok                  = tok + 1 -- '{'

	local generatedIndex = 0

	while true do
		if isToken(tokens[tok], "punctuation", "}") then
			tok = tok + 1 -- '}'
			break
		elseif isToken(tokens[tok], "punctuation", "[") then
			tok = tok + 1 -- '['

			local keyExpr, tokNext, err = parseExpressionInternal(tokens, tok, 0)
			if not keyExpr then return nil, tok, err end
			tok = tokNext

			if not isToken(tokens[tok], "punctuation", "]") then
				return nil, tok, formatErrorAfterToken(tokens[tok - 1], "Parser", "Expected ']' after key value.")
			end
			tok = tok + 1 -- ']'

			if not isToken(tokens[tok], "punctuation", "=") then
				return nil, tok, formatErrorAfterToken(tokens[tok - 1], "Parser", "Expected '=' after key.")
			end
			tok = tok + 1 -- '='

			local valueExpr, tokNext, err = parseExpressionInternal(tokens, tok, 0)
			if not valueExpr then return nil, tok, err end
			tok = tokNext

			local tableField = { key = keyExpr, value = valueExpr, generatedKey = false }
			tableInsert(tableNode.fields, tableField)
		elseif isTokenType(tokens[tok], "identifier") and isToken(tokens[tok + 1], "punctuation", "=") then
			local keyExpr = AstLiteral(tokens[tok], tokens[tok].value)
			tok           = tok + 1 -- identifier

			if not isToken(tokens[tok], "punctuation", "=") then
				return nil, tok, formatErrorAfterToken(tokens[tok - 1], "Parser", "Expected '=' after key name.")
			end
			tok = tok + 1 -- '='

			local valueExpr, tokNext, err = parseExpressionInternal(tokens, tok, 0)
			if not valueExpr then return nil, tok, err end
			tok = tokNext

			local tableField = { key = keyExpr, value = valueExpr, generatedKey = false }
			tableInsert(tableNode.fields, tableField)
		else
			generatedIndex                = generatedIndex + 1
			local keyExpr                 = AstLiteral(tokens[tok], generatedIndex)

			local valueExpr, tokNext, err = parseExpressionInternal(tokens, tok, 0)
			if not valueExpr then return nil, tok, err end
			tok = tokNext

			local tableField = { key = keyExpr, value = valueExpr, generatedKey = true }
			tableInsert(tableNode.fields, tableField)
		end

		if isToken(tokens[tok], "punctuation", ",") or isToken(tokens[tok], "punctuation", ";") then
			tok = tok + 1 -- ',' or ';'
			-- Continue...
		elseif isToken(tokens[tok], "punctuation", "}") then
			tok = tok + 1 -- '}'
			break
		else
			return nil, tok, formatErrorAfterToken(
				tokens[tok - 1], "Parser",
				"Expected ',' or '}' after value in table constructor (starting %s).",
				getRelativeLocationTextForToken(tokens, tokStart, tok - 1)
			)
		end
	end

	return tableNode, tok
end

--[[local]]
function parseExpressionInternal(tokens, tokStart, lastPrecedence) --> expression, token, error
	local tok                  = tokStart
	local canParseLookupOrCall = false
	local currentToken         = tokens[tok]
	local previousToken        = tokens[tok - 1]
	local expr

	-- identifier
	if isTokenType(currentToken, "identifier") then
		local ident, tokNext, err = parseIdentifier(tokens, tok)
		if not ident then return nil, tok, err end
		tok                  = tokNext

		expr                 = ident
		canParseLookupOrCall = true

		-- ...
	elseif isToken(currentToken, "punctuation", "...") then
		local vararg = AstVararg(currentToken)
		tok          = tok + 1 -- '...'
		expr         = vararg

		-- literal
	elseif isTokenType(currentToken, "string") or isTokenType(currentToken, "number") then
		local literal = AstLiteral(currentToken, currentToken.value)
		tok           = tok + 1 -- literal
		expr          = literal
	elseif isToken(currentToken, "keyword", "true") then
		local literal = AstLiteral(currentToken, true)
		tok           = tok + 1 -- 'true'
		expr          = literal
	elseif isToken(currentToken, "keyword", "false") then
		local literal = AstLiteral(currentToken, false)
		tok           = tok + 1 -- 'false'
		expr          = literal
	elseif isToken(currentToken, "keyword", "nil") then
		local literal = AstLiteral(currentToken, nil)
		tok           = tok + 1 -- 'nil'
		expr          = literal

		-- unary
	elseif
		(isToken(currentToken, "keyword", "not") or (isTokenType(currentToken, "punctuation") and isTokenAnyValue(currentToken, OPERATORS_UNARY)))
		and (
			(isToken(previousToken, 'punctuation', '^') and isTokenType(currentToken, 'punctuation'))
			or OPERATOR_PRECEDENCE.unary > lastPrecedence
		)
	then
		local unary                 = AstUnary(currentToken, currentToken.value)
		tok                         = tok + 1 -- operator

		local subExpr, tokNext, err = parseExpressionInternal(tokens, tok, OPERATOR_PRECEDENCE.unary - 1)
		if not subExpr then return nil, tok, err end
		unary.expression = subExpr
		tok              = tokNext

		expr             = unary

		-- Special rule: Treat '-n' as one literal (but not '-n^n' because of operator precedence).
		if
			unary.operator == "-"
			and subExpr.type == "literal"
			and type(subExpr.value) == "number"
			and isTokenType(subExpr[NODE_TOKEN], "number")
			and not (subExpr.value == 0 and NORMALIZE_MINUS_ZERO) -- We cannot store -0 in Lua 5.3+, thus we need to keep the unary expression.
		then
			subExpr.value = -subExpr.value
			subExpr[NODE_TOKEN] = unary[NODE_TOKEN]
			expr          = subExpr
		end

		-- {...}
	elseif isToken(currentToken, "punctuation", "{") then
		local tableNode, tokNext, err = parseTable(tokens, tok)
		if not tableNode then return nil, tok, err end
		tok = tokNext

		expr = tableNode

		-- function
	elseif isToken(currentToken, "keyword", "function") then
		local funcTok            = tok
		tok                      = tok + 1 -- 'function'

		local func, tokNext, err = parseFunctionParametersAndBody(tokens, tok, funcTok)
		if not func then return nil, tok, err end
		func[NODE_TOKEN] = tok
		tok        = tokNext

		expr       = func

		-- (...)
	elseif isToken(currentToken, "punctuation", "(") then
		tok = tok + 1 -- '('

		local _expr, tokNext, err = parseExpressionInternal(tokens, tok, 0)
		if not _expr then return nil, tok, err end
		tok = tokNext

		if _expr.type == "call" or _expr.type == "vararg" then
			_expr.adjustToOne = true
		end

		if not isToken(tokens[tok], "punctuation", ")") then
			return nil, tok,
				formatErrorAfterToken(tokens[tok - 1], "Parser",
					"Expected ')' (to end parenthesis expression starting %s).",
					getRelativeLocationTextForToken(tokens, tokStart, tok - 1))
		end
		tok                  = tok + 1 -- ')'

		expr                 = _expr
		canParseLookupOrCall = true
	else
		return nil, tok, formatErrorAtToken(currentToken, "Parser", "Failed parsing expression.")
	end

	assert(expr)

	-- Binary expressions, including lookups and calls.
	while true do
		currentToken = tokens[tok]

		-- a + b
		if
			(
				(isTokenType(currentToken, "punctuation") and isTokenAnyValue(currentToken, OPERATORS_BINARY))
				or isToken(currentToken, "keyword", "and")
				or isToken(currentToken, "keyword", "or")
			)
			and OPERATOR_PRECEDENCE[currentToken.value] > lastPrecedence
		then
			local rightAssociative      = isToken(currentToken, "punctuation", "..") or
				isToken(currentToken, "punctuation", "^")

			local tokOp                 = tok
			local binary                = AstBinary(currentToken, currentToken.value)
			tok                         = tok + 1 -- operator

			local lhsExpr               = expr

			local rhsExpr, tokNext, err = parseExpressionInternal(tokens, tok,
				OPERATOR_PRECEDENCE[binary.operator] + (rightAssociative and -1 or 0))
			if not rhsExpr then return nil, tok, err end
			tok          = tokNext

			binary.left  = expr
			binary.right = rhsExpr

			expr         = binary

			-- Special rule: Treat 'n/0' and '-n/0' as one literal (because that's how toLua() outputs infinity/NaN).
			if
				binary.operator == "/"
				and lhsExpr.type == "literal" and type(lhsExpr.value) == "number"
				and rhsExpr.type == "literal" and rhsExpr.value == 0
				and (
					isTokenType(lhsExpr[NODE_TOKEN], "number")
					or (
						isToken(lhsExpr[NODE_TOKEN], "punctuation", "-")
						and isTokenType(tokens[indexOf(tokens, lhsExpr[NODE_TOKEN], tokStart, tokOp - 1) + 1], "number") -- @Speed: Don't use indexOf().
					)
				)
				and isTokenType(rhsExpr[NODE_TOKEN], "number")
			then
				lhsExpr.value = lhsExpr.value / 0
				expr          = lhsExpr
			end
		elseif not canParseLookupOrCall then
			break

			-- t.k
		elseif isToken(currentToken, "punctuation", ".") then
			local lookup              = AstLookup(currentToken)
			tok                       = tok + 1 -- '.'

			local ident, tokNext, err = parseIdentifier(tokens, tok)
			if not ident then return nil, tok, err end
			tok = tokNext

			local literal = AstLiteral(ident[NODE_TOKEN], ident.name)

			lookup.object = expr
			lookup.member = literal

			expr = lookup

			-- t[k]
		elseif isToken(currentToken, "punctuation", "[") then
			local lookup                   = AstLookup(currentToken)
			tok                            = tok + 1 -- '['

			local memberExpr, tokNext, err = parseExpressionInternal(tokens, tok, 0)
			if not memberExpr then return nil, tok, err end
			tok = tokNext

			if not isToken(tokens[tok], "punctuation", "]") then
				return nil, tok, formatErrorAfterToken(tokens[tok - 1], "Parser", "Expected ']' after lookup key value.")
			end
			tok = tok + 1 -- ']'

			lookup.object = expr
			lookup.member = memberExpr

			expr = lookup

			-- f""
		elseif isTokenType(currentToken, "string") then
			local call        = AstCall(currentToken)

			local literal     = AstLiteral(currentToken, currentToken.value)
			tok               = tok + 1 -- string
			call.arguments[1] = literal

			call.callee       = expr
			expr              = call

			-- f{}
		elseif isToken(currentToken, "punctuation", "{") then
			local call = AstCall(currentToken)

			local tableNode, tokNext, err = parseTable(tokens, tok)
			if not tableNode then return nil, tok, err end
			call.arguments[1] = tableNode
			tok               = tokNext

			call.callee       = expr
			expr              = call

			-- f()
		elseif isToken(currentToken, "punctuation", "(") then
			if tok >= 2 and currentToken[TOKEN_LINESTART] > tokens[tok - 1][TOKEN_LINEEND] then
				return nil, tok,
					formatErrorAtToken(currentToken, "Parser",
						"Ambigous syntax. Is this a function call or a new statement?")
			end

			local call = AstCall(currentToken)
			tok        = tok + 1 -- '('

			if not isToken(tokens[tok], "punctuation", ")") then
				local ok, tokNext, err = parseExpressionList(tokens, tok, call.arguments)
				if not ok then return nil, tok, err end
				tok = tokNext
			end

			if not isToken(tokens[tok], "punctuation", ")") then
				return nil, tok,
					formatErrorAfterToken(tokens[tok - 1], "Parser", "Expected ')' to end argument list for call.")
			end
			tok         = tok + 1 -- ')'

			call.callee = expr
			expr        = call

			-- o:m()
		elseif isToken(currentToken, "punctuation", ":") then
			do
				local lookup              = AstLookup(currentToken)
				tok                       = tok + 1 -- ':'

				local ident, tokNext, err = parseIdentifier(tokens, tok)
				if not ident then return nil, tok, err end
				tok = tokNext

				local literal = AstLiteral(ident[NODE_TOKEN], ident.name)

				lookup.object = expr
				lookup.member = literal

				expr = lookup
			end

			do
				local call  = AstCall(tokens[tok])
				call.method = true

				if isTokenType(tokens[tok], "string") then
					local literal     = AstLiteral(tokens[tok], tokens[tok].value)
					tok               = tok + 1 -- string
					call.arguments[1] = literal
				elseif isToken(tokens[tok], "punctuation", "{") then
					local tableNode, tokNext, err = parseTable(tokens, tok)
					if not tableNode then return nil, tok, err end
					call.arguments[1] = tableNode
					tok               = tokNext
				elseif isToken(tokens[tok], "punctuation", "(") then
					if tok >= 2 and tokens[tok][TOKEN_LINESTART] > tokens[tok - 1][TOKEN_LINEEND] then
						return nil, tok,
							formatErrorAtToken(tokens[tok], "Parser",
								"Ambigous syntax. Is this a function call or a new statement?")
					end

					tok = tok + 1 -- '('

					if not isToken(tokens[tok], "punctuation", ")") then
						local ok, tokNext, err = parseExpressionList(tokens, tok, call.arguments)
						if not ok then return nil, tok, err end
						tok = tokNext
					end

					if not isToken(tokens[tok], "punctuation", ")") then
						return nil, tok,
							formatErrorAfterToken(tokens[tok - 1], "Parser",
								"Expected ')' after argument list for method call.")
					end
					tok = tok + 1 -- ')'
				else
					return nil, tok,
						formatErrorAfterToken(tokens[tok - 1], "Parser",
							"Expected '(' to start argument list for method call.")
				end

				call.callee = expr
				expr        = call
			end
		else
			break
		end

		assert(expr)
	end

	return expr, tok
end

--[[local]]
function parseExpressionList(tokens, tok, expressions) --> success, token, error
	while true do
		local expr, tokNext, err = parseExpressionInternal(tokens, tok, 0)
		if not expr then return false, tok, err end
		tok = tokNext

		tableInsert(expressions, expr)

		if not isToken(tokens[tok], "punctuation", ",") then
			return true, tok
		end
		tok = tok + 1 -- ','
	end
end

--[[local]]
function parseFunctionParametersAndBody(tokens, tokStart, funcTok) --> func, token, error
	local tok  = tokStart
	local func = AstFunction(tokens[funcTok])

	if not isToken(tokens[tok], "punctuation", "(") then
		return nil, tok,
			formatErrorAfterToken(tokens[tok - 1], "Parser", "Expected '(' to start parameter list for function.")
	end
	tok = tok + 1 -- '('

	if not isToken(tokens[tok], "punctuation", ")") then
		local ok, tokNext, err = parseNameList(tokens, tok, func.parameters, true, false)
		if not ok then return nil, tok, err end
		tok = tokNext
		-- @Cleanup: Move the vararg parameter parsing here.
	end

	if not isToken(tokens[tok], "punctuation", ")") then
		return nil, tok,
			formatErrorAfterToken(tokens[tok - 1], "Parser", "Expected ')' to end parameter list for function.")
	end
	tok = tok + 1 -- ')'

	local block, tokNext, err = parseBlock(tokens, tok, tok - 1, true)
	if not block then return nil, tok, err end
	func.body = block
	tok       = tokNext

	if not isToken(tokens[tok], "keyword", "end") then
		return nil, tok,
			formatErrorAtToken(tokens[tok], "Parser", "Expected 'end' to end function (starting %s).",
				getRelativeLocationTextForToken(tokens, tokStart, tok))
	end
	tok = tok + 1 -- 'end'

	return func, tok
end

local BLOCK_END_TOKEN_TYPES = newSet { "end", "else", "elseif", "until" }

local function parseOneOrPossiblyMoreStatements(tokens, tokStart, statements) --> success, token, error  -- The error message may be empty.
	--[[
	stat ::= ';'
	         varlist '=' explist |
	         functioncall |
	         label |
	         break |
	         goto Name |
	         do block end |
	         while exp do block end |
	         repeat block until exp |
	         if exp then block {elseif exp then block} [else block] end |
	         for Name '=' exp ',' exp [',' exp] do block end |
	         for namelist in explist do block end |
	         function funcname funcbody |
	         local function Name funcbody |
	         local attnamelist ['=' explist]

	retstat ::= return [explist] [';']
	]]
	local tok          = tokStart
	local currentToken = tokens[tok]

	-- do
	if isToken(currentToken, "keyword", "do") then
		tok = tok + 1 -- 'do'

		local block, tokNext, err = parseBlock(tokens, tok, tok - 1, true)
		if not block then return false, tok, err end
		block[NODE_TOKEN] = tok - 1
		tok         = tokNext

		if not isToken(tokens[tok], "keyword", "end") then
			return false, tok,
				formatErrorAtToken(tokens[tok], "Parser", "Expected 'end' to end 'do' block (starting %s).",
					getRelativeLocationTextForToken(tokens, tokStart, tok))
		end
		tok = tok + 1 -- 'end'

		tableInsert(statements, block)
		return true, tok

		-- while
	elseif isToken(currentToken, "keyword", "while") then
		local whileLoop          = AstWhile(currentToken)
		tok                      = tok + 1 -- 'while'

		local expr, tokNext, err = parseExpressionInternal(tokens, tok, 0)
		if not expr then return false, tok, err end
		whileLoop.condition = expr
		tok                 = tokNext

		if not isToken(tokens[tok], "keyword", "do") then
			return false, tok,
				formatErrorAfterToken(tokens[tok - 1], "Parser", "Expected 'do' to start body for 'while' loop.")
		end
		tok = tok + 1 -- 'do'

		local block, tokNext, err = parseBlock(tokens, tok, tok - 1, true)
		if not block then return false, tok, err end
		block[NODE_TOKEN] = tok - 1
		whileLoop.body = block
		tok            = tokNext

		if not isToken(tokens[tok], "keyword", "end") then
			return false, tok,
				formatErrorAtToken(tokens[tok], "Parser", "Expected 'end' to end 'while' loop (starting %s).",
					getRelativeLocationTextForToken(tokens, tokStart, tok))
		end
		tok = tok + 1 -- 'end'

		tableInsert(statements, whileLoop)
		return true, tok

		-- repeat
	elseif isToken(currentToken, "keyword", "repeat") then
		local repeatLoop          = AstRepeat(currentToken)
		tok                       = tok + 1 -- 'repeat'

		local block, tokNext, err = parseBlock(tokens, tok, tok - 1, true)
		if not block then return false, tok, err end
		repeatLoop.body = block
		tok             = tokNext

		if not isToken(tokens[tok], "keyword", "until") then
			return false, tok,
				formatErrorAtToken(tokens[tok], "Parser", "Expected 'until' at the end of 'repeat' loop (starting %s).",
					getRelativeLocationTextForToken(tokens, tokStart, tok))
		end
		tok = tok + 1 -- 'until'

		local expr, tokNext, err = parseExpressionInternal(tokens, tok, 0)
		if not expr then return false, tok, err end
		repeatLoop.condition = expr
		tok                  = tokNext

		tableInsert(statements, repeatLoop)
		return true, tok

		-- if
	elseif isToken(currentToken, "keyword", "if") then
		local ifNode             = AstIf(currentToken)
		tok                      = tok + 1 -- 'if'

		local expr, tokNext, err = parseExpressionInternal(tokens, tok, 0)
		if not expr then return false, tok, err end
		ifNode.condition = expr
		tok              = tokNext

		if not isToken(tokens[tok], "keyword", "then") then
			return false, tok, formatErrorAtToken(tokens[tok], "Parser", "Expected 'then' after 'if' condition.")
		end
		tok = tok + 1 -- 'then'

		local block, tokNext, err = parseBlock(tokens, tok, tok - 1, true)
		if not block then return false, tok, err end
		ifNode.bodyTrue  = block
		tok              = tokNext

		local ifNodeLeaf = ifNode

		while isToken(tokens[tok], "keyword", "elseif") do
			tok                                = tok + 1 -- 'elseif'

			ifNodeLeaf.bodyFalse               = AstBlock(tokens[tok])
			ifNodeLeaf.bodyFalse.statements[1] = AstIf(tokens[tok])
			ifNodeLeaf                         = ifNodeLeaf.bodyFalse.statements[1]

			local expr, tokNext, err           = parseExpressionInternal(tokens, tok, 0)
			if not expr then return false, tok, err end
			ifNodeLeaf.condition = expr
			tok                  = tokNext

			if not isToken(tokens[tok], "keyword", "then") then
				return false, tok, formatErrorAtToken(tokens[tok], "Parser", "Expected 'then' after 'elseif' condition.")
			end
			tok = tok + 1 -- 'then'

			local block, tokNext, err = parseBlock(tokens, tok, tok - 1, true)
			if not block then return false, tok, err end
			ifNodeLeaf.bodyTrue = block
			tok                 = tokNext
		end

		if isToken(tokens[tok], "keyword", "else") then
			tok = tok + 1 -- 'else'

			local block, tokNext, err = parseBlock(tokens, tok, tok - 1, true)
			if not block then return false, tok, err end
			ifNodeLeaf.bodyFalse = block
			tok                  = tokNext
		end

		if not isToken(tokens[tok], "keyword", "end") then
			return false, tok,
				formatErrorAtToken(tokens[tok], "Parser", "Expected 'end' to end 'if' statement (starting %s).",
					getRelativeLocationTextForToken(tokens, tokStart, tok))
		end
		tok = tok + 1 -- 'end'

		tableInsert(statements, ifNode)
		return true, tok

		-- for
	elseif isToken(currentToken, "keyword", "for") then
		local forLoop          = AstFor(currentToken, "")
		tok                    = tok + 1 -- 'for'

		local ok, tokNext, err = parseNameList(tokens, tok, forLoop.names, false, false)
		if not ok then return false, tok, err end
		tok = tokNext

		if isToken(tokens[tok], "keyword", "in") then
			forLoop.kind = "generic"
			tok          = tok + 1 -- 'in'
		elseif isToken(tokens[tok], "punctuation", "=") then
			if forLoop.names[2] then
				return false, tok, formatErrorAtToken(tokens[tok], "Parser", "Expected 'in' for generic loop.")
			end

			forLoop.kind = "numeric"
			tok          = tok + 1 -- '='
		else
			return false, tok, formatErrorAfterToken(tokens[tok - 1], "Parser", "Expected '=' or 'in' for 'for' loop.")
		end

		local valuesStartTok = tok

		local ok, tokNext, err = parseExpressionList(tokens, tok, forLoop.values, 0)
		if not ok then return false, tok, err end
		tok = tokNext

		if forLoop.kind ~= "numeric" then
			-- void
		elseif not forLoop.values[2] then
			return false, tok, formatErrorAtToken(tokens[valuesStartTok], "Parser", "Numeric loop: Too few values.")
		elseif forLoop.values[4] then
			-- @Cleanup: Instead of using getLeftmostToken(), make parseExpressionList() return a list of expression start tokens.
			return false, tok,
				formatErrorAtToken(getLeftmostToken(forLoop.values[4]), "Parser", "Numeric loop: Too many values.")
		end

		if not isToken(tokens[tok], "keyword", "do") then
			return false, tok,
				formatErrorAfterToken(tokens[tok - 1], "Parser", "Expected 'do' to start body for 'for' loop.")
		end
		tok = tok + 1 -- 'do'

		local block, tokNext, err = parseBlock(tokens, tok, tok - 1, true)
		if not block then return false, tok, err end
		forLoop.body = block
		tok          = tokNext

		if not isToken(tokens[tok], "keyword", "end") then
			return false, tok,
				formatErrorAtToken(tokens[tok], "Parser", "Expected 'end' to end 'for' loop (starting %s).",
					getRelativeLocationTextForToken(tokens, tokStart, tok))
		end
		tok = tok + 1 -- 'end'

		tableInsert(statements, forLoop)
		return true, tok

		-- function
	elseif isToken(currentToken, "keyword", "function") then
		local funcTok                  = tok
		local assignment               = AstAssignment(currentToken)
		tok                            = tok + 1 -- 'function'

		local targetExpr, tokNext, err = parseIdentifier(tokens, tok)
		if not targetExpr then return false, tok, err end
		tok = tokNext

		while isToken(tokens[tok], "punctuation", ".") do
			local lookup              = AstLookup(tokens[tok])
			tok                       = tok + 1 -- '.'

			local ident, tokNext, err = parseIdentifier(tokens, tok)
			if not ident then return false, tok, err end
			tok = tokNext

			local literal = AstLiteral(ident[NODE_TOKEN], ident.name)
			lookup.member = literal

			lookup.object = targetExpr
			lookup.member = literal

			targetExpr = lookup
		end

		local isMethod = isToken(tokens[tok], "punctuation", ":")

		if isMethod then
			local lookup              = AstLookup(tokens[tok])
			tok                       = tok + 1 -- ':'

			local ident, tokNext, err = parseIdentifier(tokens, tok)
			if not ident then return false, tok, err end
			tok = tokNext

			local literal = AstLiteral(ident[NODE_TOKEN], ident.name)
			lookup.member = literal

			lookup.object = targetExpr
			lookup.member = literal

			targetExpr = lookup
		end

		local func, tokNext, err = parseFunctionParametersAndBody(tokens, tok, funcTok)
		if not func then return false, tok, err end
		tok = tokNext

		if isMethod then
			local ident = AstIdentifier(func[NODE_TOKEN], "self")
			tableInsert(func.parameters, 1, ident)
		end

		assignment.targets[1] = targetExpr
		assignment.values[1]  = func

		tableInsert(statements, assignment)
		return true, tok

		-- local function
	elseif isToken(currentToken, "keyword", "local") and isToken(tokens[tok + 1], "keyword", "function") then
		local funcTok             = tok + 1
		local decl                = AstDeclaration(currentToken)
		local assignment          = AstAssignment(currentToken)
		tok                       = tok + 2 -- 'local function'

		local ident, tokNext, err = parseIdentifier(tokens, tok)
		if not ident then return false, tok, err end
		local identCopy          = parseIdentifier(tokens, tok)
		tok                      = tokNext

		local func, tokNext, err = parseFunctionParametersAndBody(tokens, tok, funcTok)
		if not func then return false, tok, err end
		tok                   = tokNext

		decl.names[1]         = ident
		assignment.targets[1] = identCopy
		assignment.values[1]  = func

		tableInsert(statements, decl)
		tableInsert(statements, assignment)
		return true, tok

		-- local
	elseif isToken(currentToken, "keyword", "local") then
		local decl             = AstDeclaration(currentToken)
		tok                    = tok + 1 -- 'local'

		local ok, tokNext, err = parseNameList(tokens, tok, decl.names, false, true)
		if not ok then return false, tok, err end
		tok = tokNext

		if isToken(tokens[tok], "punctuation", "=") then
			tok = tok + 1 -- '='

			local ok, tokNext, err = parseExpressionList(tokens, tok, decl.values)
			if not ok then return false, tok, err end
			tok = tokNext
		end

		tableInsert(statements, decl)
		return true, tok

		-- ::label::
	elseif isToken(currentToken, "punctuation", "::") then
		local label                    = AstLabel(currentToken, "")
		tok                            = tok + 1 -- '::'

		local labelIdent, tokNext, err = parseIdentifier(tokens, tok)
		if not labelIdent then return false, tok, err end
		tok = tokNext

		label.name = labelIdent.name

		if not isToken(tokens[tok], "punctuation", "::") then
			return false, tok, formatErrorAfterToken(tokens[tok - 1], "Parser", "Expected '::' after label name.")
		end
		tok = tok + 1 -- '::'

		tableInsert(statements, label)
		return true, tok

		-- goto
	elseif isToken(currentToken, "keyword", "goto") then
		local gotoNode                 = AstGoto(currentToken, "")
		tok                            = tok + 1 -- 'goto'

		local labelIdent, tokNext, err = parseIdentifier(tokens, tok)
		if not labelIdent then return false, tok, err end
		tok = tokNext

		gotoNode.name = labelIdent.name

		tableInsert(statements, gotoNode)
		return true, tok

		-- break
	elseif isToken(currentToken, "keyword", "break") then
		local breakNode = AstBreak(currentToken)
		tok             = tok + 1 -- 'break'

		tableInsert(statements, breakNode)
		return true, tok

		-- return (last)
	elseif isToken(currentToken, "keyword", "return") then
		local returnNode = AstReturn(currentToken)
		tok              = tok + 1 -- 'return'

		if tokens[tok] and not (
				(isTokenType(tokens[tok], "keyword") and isTokenAnyValue(tokens[tok], BLOCK_END_TOKEN_TYPES))
				or isToken(tokens[tok], "punctuation", ";")
				or isTokenType(tokens[tok], "end")
			) then
			local ok, tokNext, err = parseExpressionList(tokens, tok, returnNode.values)
			if not ok then return false, tok, err end
			tok = tokNext
		end

		tableInsert(statements, returnNode)
		return true, tok
	elseif isTokenType(currentToken, "keyword") then
		return false, tok, ""
	else
		local lookahead, tokNext, err = parseExpressionInternal(tokens, tok, 0)
		if not lookahead then return false, tok, err end

		if lookahead.type == "call" then
			local call = lookahead
			tok        = tokNext

			tableInsert(statements, call)
			return true, tok
		elseif isToken(tokens[tokNext], "punctuation", "=") or isToken(tokens[tokNext], "punctuation", ",") then
			local assignment = AstAssignment(tokens[tokNext])

			local ok, tokNext, err = parseExpressionList(tokens, tok, assignment.targets)
			if not ok then return false, tok, err end
			tok = tokNext

			if not isToken(tokens[tok], "punctuation", "=") then
				return false, tok, formatErrorAfterToken(tokens[tok - 1], "Parser", "Expected '=' for an assignment.")
			end
			tok = tok + 1 -- '='

			for _, targetExpr in ipairs(assignment.targets) do
				if not (targetExpr.type == "identifier" or targetExpr.type == "lookup") then
					return false, tok, formatErrorAtNode(targetExpr, "Parser", "Invalid assignment target.")
				end
			end

			local ok, tokNext, err = parseExpressionList(tokens, tok, assignment.values)
			if not ok then return false, tok, err end
			tok = tokNext

			tableInsert(statements, assignment)
			return true, tok
		else
			return false, tok, ""
		end
	end

	assert(false)
end

local statementErrorReported = false

--[[local]]
function parseBlock(tokens, tok, blockTok, stopAtEndKeyword) --> block, token, error
	local block      = AstBlock(tokens[blockTok])
	local statements = block.statements

	while tok <= #tokens and tokens[tok].type ~= "end" do
		while isToken(tokens[tok], "punctuation", ";") do
			-- Empty statements are valid in Lua 5.2+.
			tok = tok + 1 -- ';'
		end

		local statementStartTok = tok

		if stopAtEndKeyword and isTokenType(tokens[tok], "keyword") and isTokenAnyValue(tokens[tok], BLOCK_END_TOKEN_TYPES) then
			break
		end

		local ok, tokNext, err = parseOneOrPossiblyMoreStatements(tokens, tok, statements)
		if not ok then
			if not statementErrorReported then
				statementErrorReported = true
				err                    = (err ~= "" and err .. "\n" or "") ..
					formatErrorAtToken(tokens[tok], "Parser", "Failed parsing statement.")
			end
			return nil, tok, err
		end
		tok = tokNext

		if isToken(tokens[tok], "punctuation", ";") then
			tok = tok + 1 -- ';'
		end

		local lastAddedStatement = statements[#statements]

		if lastAddedStatement.type == "return" then -- Note: 'break' statements are allowed in the middle of blocks as of Lua 5.2.
			break
		elseif lastAddedStatement.type == "call" and lastAddedStatement.adjustToOne then
			statementErrorReported = true
			return nil, tok, formatErrorAtToken(tokens[statementStartTok], "Parser", "Syntax error.")
		end
	end

	return block, tok
end

-- Drops the token back-references from an AST so that the token tables can be
-- garbage collected. The tokens are only needed while parsing; afterwards the
-- nodes keep their own sourcePath/line/position information.
local function releaseTokens(node)
	if not node then return end

	node[NODE_TOKEN] = nil

	local nodeType = node.type

	if nodeType == "table" then
		for _, tableField in ipairs(node.fields) do
			releaseTokens(tableField.key)
			releaseTokens(tableField.value)
		end
	elseif nodeType == "lookup" then
		releaseTokens(node.object)
		releaseTokens(node.member)
	elseif nodeType == "unary" then
		releaseTokens(node.expression)
	elseif nodeType == "binary" then
		releaseTokens(node.left)
		releaseTokens(node.right)
	elseif nodeType == "call" then
		releaseTokens(node.callee)
		for _, expr in ipairs(node.arguments) do releaseTokens(expr) end
	elseif nodeType == "function" then
		for _, name in ipairs(node.parameters) do releaseTokens(name) end
		releaseTokens(node.body)
	elseif nodeType == "return" then
		for _, expr in ipairs(node.values) do releaseTokens(expr) end
	elseif nodeType == "block" then
		for _, statement in ipairs(node.statements) do releaseTokens(statement) end
	elseif nodeType == "declaration" then
		for _, ident in ipairs(node.names) do releaseTokens(ident) end
		for _, expr in ipairs(node.values) do releaseTokens(expr) end
	elseif nodeType == "assignment" then
		for _, expr in ipairs(node.targets) do releaseTokens(expr) end
		for _, expr in ipairs(node.values) do releaseTokens(expr) end
	elseif nodeType == "if" then
		releaseTokens(node.condition)
		releaseTokens(node.bodyTrue)
		releaseTokens(node.bodyFalse)
	elseif nodeType == "while" then
		releaseTokens(node.condition)
		releaseTokens(node.body)
	elseif nodeType == "repeat" then
		releaseTokens(node.body)
		releaseTokens(node.condition)
	elseif nodeType == "for" then
		for _, ident in ipairs(node.names) do releaseTokens(ident) end
		for _, expr in ipairs(node.values) do releaseTokens(expr) end
		releaseTokens(node.body)
	end
end

-- block, error = tokensToAst( tokens, asBlock )
-- RAM separates: The token array is compacted in place. The old code built a full
-- tokensPurged copy - a second allocation holding one pointer per token. Shifting
-- the kept tokens down by one slot reuses the array for the dummy start/end tokens.
-- Note: With comment-skipping in tokenize() there is usually nothing to drop here.
-- The dummy end token is still derived from the last raw token, so EOF error
-- message line numbers are unchanged.
local function tokensToAst(tokens, asBlock)
	local lastToken = tokens[#tokens]

	-- RAM separates: The old code built a full tokensPurged copy - a second allocation
	-- holding one pointer per token. Instead, compact the array in place, then shift it
	-- up by one slot to make room for the dummy start token. The shift walks from the
	-- end so tokens are read before their old slots are overwritten.
	local count     = 0
	for tok = 1, #tokens do
		local tokType = tokens[tok].type
		if not (tokType == "comment" or tokType == "whitespace") then
			count         = count + 1
			tokens[count] = tokens[tok]
		end
	end
	local lastKept   = tokens[count]
	for i = count, 1, -1 do tokens[i + 1] = tokens[i] end

	-- Dummy start token.
	tokens[1]        = {
		(tokens[2] and tokens[2][TOKEN_SOURCEPATH] or (lastToken and lastToken[TOKEN_SOURCEPATH] or "?")), 1, 1, 1, 1,
		type           = "start",
		value          = "",
	}

	-- Dummy end token.
	local ln         = lastToken and lastToken[TOKEN_LINEEND] or 0
	local pos        = lastToken and lastToken[TOKEN_POSITIONEND] + 1 or 0
	count            = count + 1
	tokens[count + 1] = {
		(lastKept and lastKept[TOKEN_SOURCEPATH] or (lastToken and lastToken[TOKEN_SOURCEPATH] or "?")), ln, ln, pos, pos,
		type           = "end",
		value          = "",
	}
	-- Clear stale duplicate references left behind by the compaction so the array
	-- holds no extra pointers.
	for i = count + 2, #tokens do tokens[i] = nil end

	statementErrorReported = false

	local ast, _, err
	if asBlock then
		ast, _, err = parseBlock(tokens, 2, 2, false)
	else
		ast, _, err = parseExpressionInternal(tokens, 2, 0)
	end
	if not ast then return nil, err end

	tokens = nil
	releaseTokens(ast)

	return ast
end

-- ast, error = parse( tokens )
-- NOTE: When passing a pre-tokenized array it is compacted in place (dummy start/end
-- tokens are prepended/appended) - the array must not be reused afterwards.
-- ast, error = parse( luaString [, pathForErrorMessages="?" ] )
local function parse(luaOrTokens, path)
	assertArg2("parse", 1, luaOrTokens, "string", "table")

	-- ast, error = parse( tokens )
	if type(luaOrTokens) == "table" then
		assertArg1("parse", 2, path, "nil")

		return tokensToAst(luaOrTokens, true)

		-- ast, error = parse( luaString, pathForErrorMessages )
	else
		if path == nil then
			path = "?"
		else
			assertArg1("parse", 2, path, "string")
		end

		local tokens, err = tokenize(luaOrTokens, path)
		if not tokens then return nil, err end

		return tokensToAst(tokens, true)
	end
end
local function traverseTree(node, leavesFirst, cb, parent, container, k)
	assertArg1("traverseTree", 1, node, "table")

	if type(leavesFirst) == "boolean" then
		assertArg1("traverseTree", 3, cb, "function")
	else
		leavesFirst, cb, parent, container, k = false, leavesFirst, cb, parent, container
		assertArg1("traverseTree", 2, cb, "function")
	end

	if not leavesFirst then
		local action = cb(node, parent, container, k)
		if action == "stop" then return true end
		if action == "ignorechildren" then return false end
		if action then errorf("Unknown traversal action '%s' returned from callback.", tostring(action)) end
	end

	local nodeType = node.type

	if nodeType == "identifier" or nodeType == "vararg" or nodeType == "literal" or nodeType == "break" or nodeType == "label" or nodeType == "goto" then
		-- void  No child nodes.
	elseif nodeType == "table" then
		for _, tableField in ipairs(node.fields) do
			if tableField.key and traverseTree(tableField.key, leavesFirst, cb, node, tableField, "key") then return true end
			if tableField.value and traverseTree(tableField.value, leavesFirst, cb, node, tableField, "value") then return true end
		end
	elseif nodeType == "lookup" then
		if node.object and traverseTree(node.object, leavesFirst, cb, node, node, "object") then return true end
		if node.member and traverseTree(node.member, leavesFirst, cb, node, node, "member") then return true end
	elseif nodeType == "unary" then
		if node.expression and traverseTree(node.expression, leavesFirst, cb, node, node, "expression") then return true end
	elseif nodeType == "binary" then
		if node.left and traverseTree(node.left, leavesFirst, cb, node, node, "left") then return true end
		if node.right and traverseTree(node.right, leavesFirst, cb, node, node, "right") then return true end
	elseif nodeType == "call" then
		if node.callee and traverseTree(node.callee, leavesFirst, cb, node, node, "callee") then return true end
		for i, expr in ipairs(node.arguments) do
			if traverseTree(expr, leavesFirst, cb, node, node.arguments, i) then return true end
		end
	elseif nodeType == "function" then
		for i, name in ipairs(node.parameters) do
			if traverseTree(name, leavesFirst, cb, node, node.parameters, i) then return true end
		end
		if node.body and traverseTree(node.body, leavesFirst, cb, node, node, "body") then return true end
	elseif nodeType == "return" then
		for i, expr in ipairs(node.values) do
			if traverseTree(expr, leavesFirst, cb, node, node.values, i) then return true end
		end
	elseif nodeType == "block" then
		for i, statement in ipairs(node.statements) do
			if traverseTree(statement, leavesFirst, cb, node, node.statements, i) then return true end
		end
	elseif nodeType == "declaration" then
		for i, ident in ipairs(node.names) do
			if traverseTree(ident, leavesFirst, cb, node, node.names, i) then return true end
		end
		for i, expr in ipairs(node.values) do
			if traverseTree(expr, leavesFirst, cb, node, node.values, i) then return true end
		end
	elseif nodeType == "assignment" then
		for i, expr in ipairs(node.targets) do
			if traverseTree(expr, leavesFirst, cb, node, node.targets, i) then return true end
		end
		for i, expr in ipairs(node.values) do
			if traverseTree(expr, leavesFirst, cb, node, node.values, i) then return true end
		end
	elseif nodeType == "if" then
		if node.condition and traverseTree(node.condition, leavesFirst, cb, node, node, "condition") then return true end
		if node.bodyTrue and traverseTree(node.bodyTrue, leavesFirst, cb, node, node, "bodyTrue") then return true end
		if node.bodyFalse and traverseTree(node.bodyFalse, leavesFirst, cb, node, node, "bodyFalse") then return true end
	elseif nodeType == "while" then
		if node.condition and traverseTree(node.condition, leavesFirst, cb, node, node, "condition") then return true end
		if node.body and traverseTree(node.body, leavesFirst, cb, node, node, "body") then return true end
	elseif nodeType == "repeat" then
		if node.body and traverseTree(node.body, leavesFirst, cb, node, node, "body") then return true end
		if node.condition and traverseTree(node.condition, leavesFirst, cb, node, node, "condition") then return true end
	elseif nodeType == "for" then
		for i, ident in ipairs(node.names) do
			if traverseTree(ident, leavesFirst, cb, node, node.names, i) then return true end
		end
		for i, expr in ipairs(node.values) do
			if traverseTree(expr, leavesFirst, cb, node, node.values, i) then return true end
		end
		if node.body and traverseTree(node.body, leavesFirst, cb, node, node, "body") then return true end
	else
		errorf("Invalid node type '%s'.", tostring(nodeType))
	end

	if leavesFirst then
		local action = cb(node, parent, container, k)
		if action == "stop" then return true end
		if action == "ignorechildren" then errorf("Cannot ignore children when leavesFirst is set.") end
		if action then errorf("Unknown traversal action '%s' returned from callback.", tostring(action)) end
	end

	return false
end
-- declIdent | nil  = findIdentifierDeclaration( ident )
-- declIdent.parent = decl | func | forLoop
local function findIdentifierDeclaration(ident)
	local name   = ident.name
	local parent = ident

	while true do
		local lastChild = parent
		parent          = parent[NODE_PARENT]

		if not parent then return nil end

		if parent.type == "declaration" then
			local decl = parent

			if lastChild[NODE_CONTAINER] == decl.names then
				assert(lastChild == ident)
				return ident -- ident is the declaration node.
			end
		elseif parent.type == "function" then
			local func = parent

			if lastChild[NODE_CONTAINER] == func.parameters then
				assert(lastChild == ident)
				return ident -- ident is the declaration node.
			else
				local func      = parent
				local declIdent = lastItemWith1(func.parameters, "name", name) -- Note: This will ignore any vararg parameter.
				if declIdent then return declIdent end
			end
		elseif parent.type == "for" then
			local forLoop = parent

			if lastChild[NODE_CONTAINER] == forLoop.names then
				assert(lastChild == ident)
				return ident -- ident is the declaration node.
			elseif lastChild[NODE_CONTAINER] ~= forLoop.values then
				local declIdent = lastItemWith1(forLoop.names, "name", name)
				if declIdent then return declIdent end
			end
		elseif parent.type == "block" then
			local block = parent

			-- Look through statements above lastChild.
			for i = lastChild[NODE_KEY] - 1, 1, -1 do
				local statement = block.statements[i]

				if statement.type == "declaration" then
					local decl      = statement
					local declIdent = lastItemWith1(decl.names, "name", name)
					if declIdent then return declIdent end
				end
			end
		elseif parent.type == "repeat" then
			local repeatLoop = parent

			-- Repeat loop conditions can see into the loop block.
			if lastChild == repeatLoop.condition then
				local block = repeatLoop.body

				for i = #block.statements, 1, -1 do
					local statement = block.statements[i]

					if statement.type == "declaration" then
						local decl      = statement
						local declIdent = lastItemWith1(decl.names, "name", name)
						if declIdent then return declIdent end
					end
				end
			end
		end
	end
end

-- declVararg|nil    = findVarargDeclaration( vararg )
-- declVararg.parent = func
local function findVarargDeclaration(vararg)
	local parent = vararg

	while true do
		parent = parent[NODE_PARENT]
		if not parent then return nil end

		if parent.type == "function" then
			local lastParam = parent.parameters[#parent.parameters]

			if lastParam and lastParam.type == "vararg" then
				return lastParam
			else
				return nil
			end
		end
	end
end

local function findLabel(gotoNode)
	local name   = gotoNode.name
	local parent = gotoNode

	while true do
		parent = parent[NODE_PARENT]
		if not parent then return nil end

		if parent.type == "block" then
			local block = parent

			for _, statement in ipairs(block.statements) do
				if statement.type == "label" and statement.name == name then
					return statement
				end
			end
		elseif parent.type == "function" then
			return nil
		end
	end
end
local function getNameArrayOfDeclLike(declLike)
	return declLike.names or declLike.parameters
end
-- (statement, block) | declIdent | repeatLoop | declLike = findParentStatementAndBlockOrNodeOfInterest( node, declIdent )
local function findParentStatementAndBlockOrNodeOfInterest(node, declIdent)
	while true do
		if node == declIdent then return declIdent, nil end

		local lastChild = node
		node            = node[NODE_PARENT]

		if not node then return nil end

		if node.type == "block" then return lastChild, node end
		if node.type == "declaration" and lastChild[NODE_CONTAINER] ~= node.values then return node, nil end
		if node.type == "function" then return node, nil end
		if node.type == "for" and lastChild[NODE_CONTAINER] ~= node.values then return node, nil end
		if node.type == "repeat" and lastChild == node.condition then return node, nil end
	end
end

-- foundCurrentDeclIdent = lookForCurrentDeclIdentAndRegisterCurrentIdentAsWatcherInBlock( declIdentWatchers, currentIdentOrVararg, block, statementStartIndex )
local function lookForCurrentDeclIdentAndRegisterCurrentIdentAsWatcherInBlock(declIdentWatchers, currentIdentOrVararg, block, iStart)
	local statements           = block.statements
	local currentDeclIdent     = currentIdentOrVararg.declaration

	for i = iStart, 1, -1 do
		local statement = statements[i]

		if statement.type == "declaration" then
			local decl = statement

			for _, declIdent in ipairsr(decl.names) do
				-- Note: Declaration identifiers also watch themselves. (Is this good?) :DeclarationIdentifiersWatchThemselves
				declIdentWatchers[declIdent] = declIdentWatchers[declIdent] or {}
				tableInsert(declIdentWatchers[declIdent], currentIdentOrVararg)

				if declIdent == currentDeclIdent then return true end
			end
		end
	end

	return false
end

local function getInformationAboutIdentifiersAndUpdateReferences(node)
	local idents            = {}
	local declIdentWatchers = setmetatable({}, {__mode = "k"}) --[[ [declIdent1]={identOrVararg1,...}, ... ]]

	traverseTree(node, function(node, parent, container, key)
		node[NODE_PARENT]    = parent
		node[NODE_CONTAINER] = container
		node[NODE_KEY]       = key

		if node.type == "identifier" or node.type == "vararg" then
			local currentIdentOrVararg       = node
			local findDecl                   = (currentIdentOrVararg.type == "identifier") and findIdentifierDeclaration or
				findVarargDeclaration
			local currentDeclIdent           = findDecl(currentIdentOrVararg) -- We can call this because all parents and previous nodes already have their references updated at this point.
			currentIdentOrVararg.declaration = currentDeclIdent

			-- if currentDeclIdent then  print(F("%s:%d: %s '%s'", currentIdentOrVararg.sourcePath, currentIdentOrVararg.line, identType, (currentIdentOrVararg.name or "...")))  end -- DEBUG

			tableInsert(idents, currentIdentOrVararg)

			-- Determine visible declarations for the identifier.
			local block = currentIdentOrVararg -- Start node for while loop.

			while true do
				local statementOrInterest
				statementOrInterest, block = findParentStatementAndBlockOrNodeOfInterest(block, currentDeclIdent)

				if not statementOrInterest then
					-- We should only get here for globals (i.e. there should be no declaration).
					assert(not currentDeclIdent)
					return
				end

				if block then
					local statement = statementOrInterest

					assert(type(statement[NODE_KEY]) == "number")
					assert(statement[NODE_CONTAINER] == block.statements)

					if lookForCurrentDeclIdentAndRegisterCurrentIdentAsWatcherInBlock(declIdentWatchers, currentIdentOrVararg, block, statement[NODE_KEY] - 1) then
						return
					end

					-- We found the current declIdent - don't look for more other declIdents to watch!
				elseif statementOrInterest == currentDeclIdent then
					local declIdent = statementOrInterest

					-- :DeclarationIdentifiersWatchThemselves
					declIdentWatchers[declIdent] = declIdentWatchers[declIdent] or {}
					tableInsert(declIdentWatchers[declIdent], currentIdentOrVararg)

					return

					-- We can jump from repeat loop conditions into the loop's body.
				elseif statementOrInterest.type == "repeat" then
					local repeatLoop = statementOrInterest
					block            = repeatLoop.body -- Start node for while loop.

					if lookForCurrentDeclIdentAndRegisterCurrentIdentAsWatcherInBlock(declIdentWatchers, currentIdentOrVararg, block, #block.statements) then
						return
					end

					-- Declaration-likes have names we want to watch.
					-- Note that findParentStatementAndBlockOrNodeOfInterest() is smart and skipped declaration-likes that we should completely ignore.
				else
					local declLike = statementOrInterest
					block          = declLike -- Start node for while loop.

					for _, declIdent in ipairsr(getNameArrayOfDeclLike(declLike)) do
						-- :DeclarationIdentifiersWatchThemselves
						declIdentWatchers[declIdent] = declIdentWatchers[declIdent] or {}
						tableInsert(declIdentWatchers[declIdent], currentIdentOrVararg)

						if declIdent == currentDeclIdent then return end
					end
				end
			end
		elseif node.type == "goto" then
			local gotoNode = node
			gotoNode.label = findLabel(gotoNode) -- We can call this because all relevant 'parent' references have been updated at this point.
		end
	end)

	return idents, declIdentWatchers
end
local generateName
local nameCache = {}
do
	local BANK_LETTERS  =
	"etaoinshrdlcumwfgypbvkxjqzETAOINSHRDLCUMWFGYPBVKXJQZ" -- http://en.wikipedia.org/wiki/Letter_frequencies
	local BANK_ALPHANUM = "etaoinshrdlcumwfgypbvkxjqzETAOINSHRDLCUMWFGYPBVKXJQZ0123456789"

	local ILLEGAL_NAMES = {}
	for name in pairs(KEYWORDS) do ILLEGAL_NAMES[name] = true end
	if HANDLE_ENV then ILLEGAL_NAMES._ENV = true end

	--[[local]]
	function generateName(nameGeneration)
		if not nameCache[nameGeneration] then
			-- @Cleanup: Output the most significant byte first. (We need to know the length beforehand then, probably, so we use the correct bank.)
			local charBytes = {}
			local g         = nameGeneration

			for i = 1, 1 / 0 do
				g              = g - 1
				local charBank  = (i == 1) and BANK_LETTERS or BANK_ALPHANUM
				local charIndex = g % #charBank + 1
				charBytes[i]    = stringByte(charBank, charIndex)
				g               = mathFloor(g / #charBank)

				if g == 0 then break end
			end

			local name = stringChar(tableUnpack(charBytes))
			if ILLEGAL_NAMES[name] then
				-- We will probably realistically never get here, partially because of the limited amount of locals and upvalues Lua allows.
				name = name .. "_"
			end
			nameCache[nameGeneration] = name
		end

		return nameCache[nameGeneration]
	end

	-- for nameGeneration = 1, 3500 do  print(generateName(nameGeneration))  end ; error("TEST")
	-- for pow = 0, 32 do  print(generateName(2^pow))  end ; error("TEST")
end

local function clearCaches()
	for k in pairs(nameCache) do nameCache[k] = nil end
end
-- stats = minify( node )
local function minify(node)
	assertArg1("minify", 1, node, "table")
	local stats                         = Stats()

	-- @Cleanup: Use findShadows()?
	local idents, declIdentWatchers     = getInformationAboutIdentifiersAndUpdateReferences(node)
	-- local funcInfos                                    = getInformationAboutFunctions(node)
	-- local declIdentReadCount, declIdentAssignmentCount = getAccessesOfDeclaredNames(funcInfos, identInfos, declIdentWatchers)

	local allDeclIdents                 = {}

	for _, ident in ipairs(idents) do
		local declIdent = (ident.type == "identifier") and ident.declaration or nil

		if declIdent and not allDeclIdents[declIdent] then
			tableInsert(allDeclIdents, declIdent)
			allDeclIdents[declIdent] = true
		end
	end

	--
	-- Make sure frequencies affect who gets shorter names first.
	-- (This doesn't seem that useful at the moment. 2021-06-16)
	--
	--[[ :SortBeforeRename
	tableSort(allDeclIdents, function(a, b)
		if a.type == "vararg" or b.type == "vararg" then
			return a.id < b.id -- We don't care about varargs.
		end

		local aWatchers = declIdentWatchers[a.declaration]
		local bWatchers = declIdentWatchers[b.declaration]

		if not (aWatchers and bWatchers) then
			return a.id < a.id -- We don't care about globals.
		end

		if #aWatchers ~= #bWatchers then
			return #aWatchers < #bWatchers
		end

		return a.id < b.id
	end)
	--]]

	--
	-- Rename locals!
	--
	local renamed           = { --[[ [declIdent1]=true, ... ]] }
	local maxNameGeneration = 0

	--[[ :SortBeforeRename
	local remoteWatchers = {}
	--]]

	-- Assign generated names to declarations.
	for _, declIdent in ipairs(allDeclIdents) do
		local newName

		if declIdent.name == "_ENV" and HANDLE_ENV then
			-- There are probably some cases where we can safely rename _ENV,
			-- but it's likely not worth the effort to detect that.
			newName = "_ENV"
		else
			for nameGeneration = 1, 1 / 0 do
				newName         = generateName(nameGeneration)
				local collision = false

				for _, watcherIdent in ipairs(declIdentWatchers[declIdent] or {}) do
					local watcherDeclIdent = watcherIdent.declaration

					-- Local watcher.
					if watcherDeclIdent then
						if renamed[watcherDeclIdent] and watcherDeclIdent.name == newName then
							collision = true
							break
						end

						-- Global watcher.
					elseif watcherIdent.name == newName then
						collision = true
						break
					end
				end --for declIdentWatchers

				--[[ :SortBeforeRename
				if not collision and remoteWatchers[declIdent] then
					for _, watcherDeclIdent in ipairs(remoteWatchers[declIdent]) do
						if watcherDeclIdent.name == newName then
							collision = true
							break
						end
					end
				end
				--]]

				if not collision then
					maxNameGeneration = mathMax(maxNameGeneration, nameGeneration)
					break
				end
			end --for nameGeneration
		end

		--[[ :SortBeforeRename
		for _, watcherIdent in ipairs(declIdentWatchers[declIdent]) do
			local watcherDeclIdent = watcherIdent.declaration

			if watcherDeclIdent and watcherDeclIdent ~= declIdent then
				remoteWatchers[watcherDeclIdent] = remoteWatchers[watcherDeclIdent] or {}

				if not remoteWatchers[watcherDeclIdent][declIdent] then
					tableInsert(remoteWatchers[watcherDeclIdent], declIdent)
					remoteWatchers[watcherDeclIdent][declIdent] = true
				end
			end
		end
		--]]

		if declIdent.name ~= newName then
			declIdent.name    = newName
			stats.renameCount = stats.renameCount + 1
		end
		renamed[declIdent] = true
	end --for allDeclIdents

	stats.generatedNameCount = maxNameGeneration
	-- print("maxNameGeneration", maxNameGeneration) -- DEBUG

	-- Rename all remaining identifiers.
	for _, ident in ipairs(idents) do
		local declIdent = (ident.type == "identifier") and ident.declaration or nil

		if declIdent and ident.name ~= declIdent.name then
			ident.name        = declIdent.name
			stats.renameCount = stats.renameCount + 1
		end
	end

	return stats
end
local toLua
do
	local writeNode
	local writeStatements

	-- lastOutput = "" | "alphanum" | "number" | "-" | "."

	local function isNumberInRange(n, min, max)
		return n ~= nil and n >= min and n <= max
	end

	local function canNodeBeName(node)
		return node.type == "literal" and type(node.value) == "string" and stringFind(node.value, "^[%a_][%w_]*$") and
			not KEYWORDS[node.value]
	end

	-- ensureSpaceIfNotPretty( buffer, pretty, lastOutput, value [, value2 ] )
	local function ensureSpaceIfNotPretty(buffer, pretty, lastOutput, value, value2)
		if not pretty and (lastOutput == value or lastOutput == value2) then
			tableInsert(buffer, " ")
		end
	end

	local function choosePretty(node, prettyFallback)
		if node.pretty ~= nil then return node.pretty end
		return prettyFallback
	end

	local function writeLua(buffer, lua, lastOutput)
		tableInsert(buffer, lua)
		return lastOutput
	end

	local function writeAlphanum(buffer, pretty, s, lastOutput)
		ensureSpaceIfNotPretty(buffer, pretty, lastOutput, "alphanum", "number")
		lastOutput = writeLua(buffer, s, "alphanum")
		return "alphanum"
	end
	local function writeNumber(buffer, pretty, n, lastOutput)
		local nStr = formatNumber(n)
		if (lastOutput == "-" and stringByte(nStr, 1) == 45 --[[ "-" ]]) or lastOutput == "." then
			lastOutput = writeLua(buffer, " ", "")
		else
			ensureSpaceIfNotPretty(buffer, pretty, lastOutput, "alphanum", "number")
		end
		lastOutput = writeLua(buffer, nStr, "number")
		return "number"
	end

	-- Returns nil and a message or error.
	local function writeCommaSeparatedList(buffer, pretty, indent, lastOutput, expressions, writeAttributes, nodeCb)
		for i, expr in ipairs(expressions) do
			if i > 1 then
				lastOutput = writeLua(buffer, ",", "")
				if pretty then lastOutput = writeLua(buffer, " ", "") end
			end

			local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, expr, true, nodeCb)
			if not ok then return nil, lastOutput end

			if writeAttributes and expr.type == "identifier" and expr.attribute ~= "" then
				lastOutput = writeLua(buffer, "<", "")
				lastOutput = writeAlphanum(buffer, pretty, expr.attribute, lastOutput)
				lastOutput = writeLua(buffer, ">", "")
			end
		end

		return true, lastOutput
	end

	local function isStatementFunctionDeclaration(statement, statementNext)
		return true
			and statement.type == "declaration" and statementNext.type == "assignment"
			and #statement.names == 1 and #statement.values == 0
			and #statementNext.targets == 1 and #statementNext.values == 1
			and statementNext.targets[1].type == "identifier" and
			statement.names[1].name == statementNext.targets[1].name
			and statementNext.values[1].type == "function"
	end

	local function writeIndentationIfPretty(buffer, pretty, indent, lastOutput)
		if pretty and indent > 0 then
			lastOutput = writeLua(buffer, stringRep("\t", indent), "")
		end
		return lastOutput
	end

	-- Returns nil and a message or error.
	local function writeFunctionParametersAndBody(buffer, pretty, indent, lastOutput, func, explicitParams, selfParam,
												  nodeCb)
		lastOutput = writeLua(buffer, "(", "")

		if selfParam then
			if nodeCb then nodeCb(selfParam, buffer) end
			tableInsert(buffer, selfParam.prefix)
			tableInsert(buffer, selfParam.suffix)
		end

		local ok; ok, lastOutput = writeCommaSeparatedList(buffer, pretty, indent, lastOutput, explicitParams, false,
			nodeCb)
		if not ok then return nil, lastOutput end

		lastOutput = writeLua(buffer, ")", "")
		if nodeCb then nodeCb(func.body, buffer) end
		pretty = choosePretty(func.body, pretty)
		tableInsert(buffer, func.body.prefix)
		if pretty then lastOutput = writeLua(buffer, "\n", "") end

		local ok; ok, lastOutput = writeStatements(buffer, pretty, indent + 1, lastOutput, func.body.statements, nodeCb)
		if not ok then return nil, lastOutput end

		lastOutput = writeIndentationIfPretty(buffer, pretty, indent, lastOutput)
		tableInsert(buffer, func.body.suffix)
		lastOutput = writeAlphanum(buffer, pretty, "end", lastOutput)

		return true, lastOutput
	end

	-- Returns nil and a message or error.
	--[[local]]
	function writeStatements(buffer, pretty, indent, lastOutput, statements, nodeCb)
		local skipNext = false

		for i, statement in ipairs(statements) do
			if skipNext then
				skipNext = false
			else
				local statementNext = statements[i + 1]
				lastOutput          = writeIndentationIfPretty(buffer, pretty, indent, lastOutput)

				if statementNext and isStatementFunctionDeclaration(statement, statementNext) then
					local decl       = statement
					local assignment = statementNext
					local func       = assignment.values[1]
					local pretty     = choosePretty(assignment, pretty)

					if nodeCb then
						nodeCb(decl, buffer)
						nodeCb(assignment, buffer)
						nodeCb(func, buffer)
					end

					tableInsert(buffer, decl.prefix)
					tableInsert(buffer, assignment.prefix)
					tableInsert(buffer, func.prefix)

					lastOutput = writeAlphanum(buffer, pretty, "local function", lastOutput)
					lastOutput = writeLua(buffer, " ", "")

					if nodeCb then nodeCb(decl.names[1], buffer) end

					tableInsert(buffer, decl.names[1].prefix)
					local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, assignment.targets[1], true,
						nodeCb)
					if not ok then return nil, lastOutput end
					tableInsert(buffer, decl.names[1].suffix)

					local ok; ok, lastOutput = writeFunctionParametersAndBody(buffer, choosePretty(func, pretty), indent,
						lastOutput, func, func.parameters, nil, nodeCb)
					if not ok then return nil, lastOutput end

					tableInsert(buffer, func.suffix)
					tableInsert(buffer, assignment.suffix)
					tableInsert(buffer, decl.suffix)

					skipNext = true
				else
					local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, statement, true, nodeCb)
					if not ok then return nil, lastOutput end

					if statement.type == "call" then
						lastOutput = writeLua(buffer, ";", "") -- @Ugly way of handling call statements. (But what way would be better?)
					end
				end

				if pretty then lastOutput = writeLua(buffer, "\n", "") end
			end
		end

		return true, lastOutput
	end

	local function doesExpressionNeedParenthesisIfOnTheLeftSide(expr)
		local nodeType = expr.type
		-- Some things, like "binary" or "vararg", are not here because those expressions add their own parentheses.
		return nodeType == "literal" or nodeType == "table" or nodeType == "function"
	end

	-- Returns nil and a message or error.
	local function writeLookup(buffer, pretty, indent, lastOutput, lookup, forMethodCall, nodeCb)
		local objNeedParens = doesExpressionNeedParenthesisIfOnTheLeftSide(lookup.object)
		if objNeedParens then lastOutput = writeLua(buffer, "(", "") end

		local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, lookup.object, false, nodeCb)
		if not ok then return nil, lastOutput end

		if objNeedParens then lastOutput = writeLua(buffer, ")", "") end

		if canNodeBeName(lookup.member) then
			lastOutput = writeLua(buffer, (forMethodCall and ":" or "."), "")
			if nodeCb then nodeCb(lookup.member, buffer) end
			tableInsert(buffer, lookup.member.prefix)
			lastOutput = writeAlphanum(buffer, pretty, lookup.member.value, lastOutput)
			tableInsert(buffer, lookup.member.suffix)
		elseif forMethodCall then
			return nil, "Error: AST: Callee for method call is not a lookup."
		else
			lastOutput = writeLua(buffer, "[", "")

			local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, lookup.member, true, nodeCb)
			if not ok then return nil, lastOutput end

			lastOutput = writeLua(buffer, "]", "")
		end

		return true, lastOutput
	end

	local function isAssignmentFunctionAssignment(assignment)
		if #assignment.targets ~= 1 then return false end
		if #assignment.values ~= 1 then return false end
		if assignment.values[1].type ~= "function" then return false end

		local targetExpr = assignment.targets[1]
		while true do
			if targetExpr.type == "identifier" then
				return true
			elseif not (targetExpr.type == "lookup" and canNodeBeName(targetExpr.member)) then
				return false
			end
			targetExpr = targetExpr.object
		end
	end

	-- Returns nil and a message or error.
	local function writeBinaryOperatorChain(buffer, pretty, indent, lastOutput, binary, nodeCb)
		local l = binary.left
		local r = binary.right

		if l.type == "binary" and l.operator == binary.operator then
			if nodeCb then nodeCb(l, buffer) end
			tableInsert(buffer, l.prefix)
			local ok; ok, lastOutput = writeBinaryOperatorChain(buffer, choosePretty(l, pretty), indent, lastOutput, l,
				nodeCb)
			if not ok then return nil, lastOutput end
			tableInsert(buffer, l.suffix)
		else
			local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, l, false, nodeCb)
			if not ok then return nil, lastOutput end
		end

		if pretty then lastOutput = writeLua(buffer, " ", "") end

		if binary.operator == ".." then ensureSpaceIfNotPretty(buffer, pretty, lastOutput, "number") end

		local nextOutput = (
			(binary.operator == "-" and "-") or
			(binary.operator == ".." and ".") or
			(stringFind(binary.operator, "%w") and "alphanum") or
			""
		)
		if nextOutput ~= "" then ensureSpaceIfNotPretty(buffer, pretty, lastOutput, nextOutput) end
		lastOutput = writeLua(buffer, binary.operator, nextOutput)

		if pretty then lastOutput = writeLua(buffer, " ", "") end

		if r.type == "binary" and r.operator == binary.operator then
			if nodeCb then nodeCb(r, buffer) end
			tableInsert(buffer, r.prefix)
			local ok; ok, lastOutput = writeBinaryOperatorChain(buffer, choosePretty(r, pretty), indent, lastOutput, r,
				nodeCb)
			if not ok then return nil, lastOutput end
			tableInsert(buffer, r.suffix)
		else
			local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, r, false, nodeCb)
			if not ok then return nil, lastOutput end
		end

		return true, lastOutput
	end

	-- success, lastOutput = writeNode( buffer, pretty, indent, lastOutput, node, maySafelyOmitParens, nodeCallback )
	-- Returns nil and a message or error.
	--[[local]]
	function writeNode(buffer, pretty, indent, lastOutput, node, maySafelyOmitParens, nodeCb)
		if nodeCb then nodeCb(node, buffer) end
		pretty = choosePretty(node, pretty)

		tableInsert(buffer, node.prefix)

		local nodeType = node.type

		-- Expressions:

		if nodeType == "identifier" then
			local ident = node
			lastOutput = writeAlphanum(buffer, pretty, ident.name, lastOutput)
		elseif nodeType == "vararg" then
			local vararg = node
			if vararg.adjustToOne then lastOutput = writeLua(buffer, "(", "") end
			if lastOutput == "." then lastOutput = writeLua(buffer, " ", ".") end
			lastOutput = writeLua(buffer, "...", ".")
			if vararg.adjustToOne then lastOutput = writeLua(buffer, ")", "") end
		elseif nodeType == "literal" then
			local literal = node

			if node.value == 0 and NORMALIZE_MINUS_ZERO then
				lastOutput = writeNumber(buffer, pretty, 0, lastOutput) -- Avoid writing '-0' sometimes.
			elseif literal.value == 1 / 0 then
				lastOutput = writeAlphanum(buffer, pretty, "(1/0)", lastOutput) -- Note: We parse this as one literal.
			elseif literal.value == -1 / 0 then
				lastOutput = writeLua(buffer, "(-1/0)", "")         -- Note: We parse this as one literal.
			elseif literal.value ~= literal.value then
				lastOutput = writeLua(buffer, "(0/0)", "")          -- Note: We parse this as one literal.
			elseif literal.value == nil or type(literal.value) == "boolean" then
				lastOutput = writeAlphanum(buffer, pretty, tostring(literal.value), lastOutput)
			elseif type(literal.value) == "number" or (jit and type(literal.value) == "cdata" and tonumber(literal.value)) then
				lastOutput = writeNumber(buffer, pretty, literal.value, lastOutput)
			elseif type(literal.value) == "string" then
				-- @Speed: Cache!
				local R           = isNumberInRange
				local s           = literal.value
				local doubleCount = countString(s, '"', true)
				local singleCount = countString(s, "'", true)
				local quote       = singleCount < doubleCount and "'" or '"'
				local quoteByte   = stringByte(quote)
				local pos         = 1

				lastOutput        = writeLua(buffer, quote, "")

				while pos <= #s do
					local b1, b2, b3, b4 = stringByte(s, pos, pos + 3)

					-- Printable ASCII.
					if R(b1, 32, 126) then
						if b1 == quoteByte then
							tableInsert(buffer, "\\"); tableInsert(buffer, quote); pos = pos + 1
						elseif b1 == 92 then
							tableInsert(buffer, [[\\]]); pos = pos + 1
						else
							tableInsert(buffer, stringSub(s, pos, pos)); pos = pos + 1
						end

						-- Multi-byte UTF-8 sequence.
					elseif b2 and R(b1, 194, 223) and R(b2, 128, 191) then
						tableInsert(buffer, stringSub(s, pos, pos + 1)); pos = pos + 2
					elseif b3 and b1 == 224 and R(b2, 160, 191) and R(b3, 128, 191) then
						tableInsert(buffer, stringSub(s, pos, pos + 2)); pos = pos + 3
					elseif b3 and R(b1, 225, 236) and R(b2, 128, 191) and R(b3, 128, 191) then
						tableInsert(buffer, stringSub(s, pos, pos + 2)); pos = pos + 3
					elseif b3 and b1 == 237 and R(b2, 128, 159) and R(b3, 128, 191) then
						tableInsert(buffer, stringSub(s, pos, pos + 2)); pos = pos + 3
					elseif b3 and R(b1, 238, 239) and R(b2, 128, 191) and R(b3, 128, 191) then
						tableInsert(buffer, stringSub(s, pos, pos + 2)); pos = pos + 3
					elseif b4 and b1 == 240 and R(b2, 144, 191) and R(b3, 128, 191) and R(b4, 128, 191) then
						tableInsert(buffer, stringSub(s, pos, pos + 3)); pos = pos + 4
					elseif b4 and R(b1, 241, 243) and R(b2, 128, 191) and R(b3, 128, 191) and R(b4, 128, 191) then
						tableInsert(buffer, stringSub(s, pos, pos + 3)); pos = pos + 4
					elseif b4 and b1 == 244 and R(b2, 128, 143) and R(b3, 128, 191) and R(b4, 128, 191) then
						tableInsert(buffer, stringSub(s, pos, pos + 3)); pos = pos + 4

						-- Escape sequence.
					elseif b1 == 7 then
						tableInsert(buffer, [[\a]]); pos = pos + 1
					elseif b1 == 8 then
						tableInsert(buffer, [[\b]]); pos = pos + 1
					elseif b1 == 9 then
						tableInsert(buffer, [[\t]]); pos = pos + 1
					elseif b1 == 10 then
						tableInsert(buffer, [[\n]]); pos = pos + 1
					elseif b1 == 11 then
						tableInsert(buffer, [[\v]]); pos = pos + 1
					elseif b1 == 12 then
						tableInsert(buffer, [[\f]]); pos = pos + 1
					elseif b1 == 13 then
						tableInsert(buffer, [[\r]]); pos = pos + 1

						-- Other control character or anything else.
					elseif b2 and R(b2, 48, 57) then
						tableInsert(buffer, F([[\%03d]], b1)); pos = pos + 1
					else
						tableInsert(buffer, F([[\%d]], b1)); pos = pos + 1
					end
				end

				lastOutput = writeLua(buffer, quote, "")
			else
				return nil, F("Error: Failed outputting '%s' value '%s'.", type(literal.value), tostring(literal.value))
			end
		elseif nodeType == "table" then
			local tableNode = node
			lastOutput      = writeLua(buffer, "{", "")

			for i, tableField in ipairs(tableNode.fields) do
				if i > 1 then
					lastOutput = writeLua(buffer, ",", "")
					if pretty then lastOutput = writeLua(buffer, " ", "") end
				end

				if tableField.generatedKey then
					if tableField.key then
						if nodeCb then nodeCb(tableField.key, buffer) end
						tableInsert(buffer, tableField.key.prefix)
						tableInsert(buffer, tableField.key.suffix)
					end
				else
					if canNodeBeName(tableField.key) then
						if nodeCb then nodeCb(tableField.key, buffer) end
						tableInsert(buffer, tableField.key.prefix)
						lastOutput = writeLua(buffer, tableField.key.value, "alphanum")
						tableInsert(buffer, tableField.key.suffix)
					else
						lastOutput = writeLua(buffer, "[", "")

						local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, tableField.key, true,
							nodeCb)
						if not ok then return nil, lastOutput end

						lastOutput = writeLua(buffer, "]", "")
					end

					lastOutput = writeLua(buffer, "=", "")
				end

				local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, tableField.value, (not pretty),
					nodeCb)
				if not ok then return nil, lastOutput end
			end

			lastOutput = writeLua(buffer, "}", "")
		elseif nodeType == "lookup" then
			local lookup   = node
			local ok; ok, lastOutput = writeLookup(buffer, pretty, indent, lastOutput, lookup, false, nodeCb)
			if not ok then return nil, lastOutput end
		elseif nodeType == "unary" then
			local unary             = node
			local operatorOutput    = (unary.operator == "-" and "-") or
				(stringFind(unary.operator, "%w") and "alphanum") or ("")
			local prettyAndAlphanum = pretty and operatorOutput == "alphanum"

			if prettyAndAlphanum and not maySafelyOmitParens then lastOutput = writeLua(buffer, "(", "") end -- @Polish: Only output parentheses around child unaries/binaries if associativity requires it.

			if lastOutput == "-" and operatorOutput == "-" then
				lastOutput = writeLua(buffer, " ", "")
			elseif operatorOutput ~= "" then
				ensureSpaceIfNotPretty(buffer, pretty, lastOutput, operatorOutput)
			end
			lastOutput = writeLua(buffer, unary.operator, operatorOutput)

			if prettyAndAlphanum then lastOutput = writeLua(buffer, " ", "") end

			local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, unary.expression, false, nodeCb)
			if not ok then return nil, lastOutput end

			if prettyAndAlphanum and not maySafelyOmitParens then lastOutput = writeLua(buffer, ")", "") end
		elseif nodeType == "binary" then
			local binary = node
			local op     = binary.operator

			if not maySafelyOmitParens then lastOutput = writeLua(buffer, "(", "") end -- @Polish: Only output parentheses around child unaries/binaries if associativity requires it.

			if op == ".." or op == "and" or op == "or" or op == "+" or op == "*" or op == "&" or op == "|" then
				local ok; ok, lastOutput = writeBinaryOperatorChain(buffer, pretty, indent, lastOutput, binary, nodeCb)
				if not ok then return nil, lastOutput end
			else
				local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, binary.left, false, nodeCb)
				if not ok then return nil, lastOutput end

				local operatorOutput = ((op == "-" and "-") or (stringFind(op, "%w") and "alphanum") or (""))

				if pretty then lastOutput = writeLua(buffer, " ", "") end

				if operatorOutput ~= "" then ensureSpaceIfNotPretty(buffer, pretty, lastOutput, operatorOutput) end
				lastOutput = writeLua(buffer, op, operatorOutput)

				if pretty then lastOutput = writeLua(buffer, " ", "") end

				local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, binary.right, false, nodeCb)
				if not ok then return nil, lastOutput end
			end

			if not maySafelyOmitParens then lastOutput = writeLua(buffer, ")", "") end
		elseif nodeType == "call" then -- Can be statement too.
			local call = node

			if call.adjustToOne then lastOutput = writeLua(buffer, "(", "") end

			if call.method then
				local lookup = call.callee

				if lookup.type ~= "lookup" then
					return nil, "Error: AST: Callee for method call is not a lookup."
				end

				if nodeCb then nodeCb(lookup, buffer) end

				tableInsert(buffer, lookup.prefix)
				local ok; ok, lastOutput = writeLookup(buffer, choosePretty(lookup, pretty), indent, lastOutput, lookup,
					true, nodeCb)
				if not ok then return nil, lastOutput end
				tableInsert(buffer, lookup.suffix)
			else
				local needParens = doesExpressionNeedParenthesisIfOnTheLeftSide(call.callee)
				if needParens then lastOutput = writeLua(buffer, "(", "") end

				local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, call.callee, false, nodeCb)
				if not ok then return nil, lastOutput end

				if needParens then lastOutput = writeLua(buffer, ")", "") end
			end

			lastOutput = writeLua(buffer, "(", "")

			local ok; ok, lastOutput = writeCommaSeparatedList(buffer, pretty, indent, lastOutput, call.arguments, false,
				nodeCb)
			if not ok then return nil, lastOutput end

			lastOutput = writeLua(buffer, ")", "")
			if call.adjustToOne then lastOutput = writeLua(buffer, ")", "") end
		elseif nodeType == "function" then
			local func = node
			lastOutput = writeAlphanum(buffer, pretty, "function", lastOutput)

			local ok; ok, lastOutput = writeFunctionParametersAndBody(buffer, pretty, indent, lastOutput, func,
				func.parameters, nil, nodeCb)
			if not ok then return nil, lastOutput end

			-- Statements:
		elseif nodeType == "break" then
			lastOutput = writeAlphanum(buffer, pretty, "break", lastOutput)
			lastOutput = writeLua(buffer, ";", "")
		elseif nodeType == "return" then
			local returnNode = node
			lastOutput       = writeAlphanum(buffer, pretty, "return", lastOutput)

			if returnNode.values[1] then
				if pretty then lastOutput = writeLua(buffer, " ", "") end

				local ok; ok, lastOutput = writeCommaSeparatedList(buffer, pretty, indent, lastOutput, returnNode.values,
					false, nodeCb)
				if not ok then return nil, lastOutput end
			end

			lastOutput = writeLua(buffer, ";", "")
		elseif nodeType == "label" then
			local label = node
			local name  = label.name
			if not (stringFind(name, "^[%a_][%w_]*$") and not KEYWORDS[name]) then
				return nil, F("Error: AST: Invalid label '%s'.", name)
			end
			lastOutput = writeLua(buffer, "::", "")
			lastOutput = writeAlphanum(buffer, pretty, name, lastOutput)
			lastOutput = writeLua(buffer, "::", "")
			lastOutput = writeLua(buffer, ";", "")
		elseif nodeType == "goto" then
			local gotoNode = node
			local name     = gotoNode.name
			if not (stringFind(name, "^[%a_][%w_]*$") and not KEYWORDS[name]) then
				return nil, F("Error: AST: Invalid label '%s'.", name)
			end
			lastOutput = writeAlphanum(buffer, pretty, "goto", lastOutput)
			lastOutput = writeLua(buffer, " ", "")
			lastOutput = writeAlphanum(buffer, pretty, name, lastOutput)
			lastOutput = writeLua(buffer, ";", "")
		elseif nodeType == "block" then
			local block = node
			lastOutput  = writeAlphanum(buffer, pretty, "do", lastOutput)
			if pretty then lastOutput = writeLua(buffer, "\n", "") end

			local ok; ok, lastOutput = writeStatements(buffer, pretty, indent + 1, lastOutput, block.statements, nodeCb)
			if not ok then return nil, lastOutput end

			lastOutput = writeIndentationIfPretty(buffer, pretty, indent, lastOutput)
			lastOutput = writeAlphanum(buffer, pretty, "end", lastOutput)
		elseif nodeType == "declaration" then
			local decl = node
			lastOutput = writeAlphanum(buffer, pretty, "local", lastOutput)
			lastOutput = writeLua(buffer, " ", "")

			if not decl.names[1] then return nil, "Error: AST: Missing name(s) for declaration." end

			local ok; ok, lastOutput = writeCommaSeparatedList(buffer, pretty, indent, lastOutput, decl.names, true,
				nodeCb)
			if not ok then return nil, lastOutput end

			if decl.values[1] then
				if pretty then lastOutput = writeLua(buffer, " ", "") end
				lastOutput = writeLua(buffer, "=", "")
				if pretty then lastOutput = writeLua(buffer, " ", "") end

				local ok; ok, lastOutput = writeCommaSeparatedList(buffer, pretty, indent, lastOutput, decl.values, false,
					nodeCb)
				if not ok then return nil, lastOutput end
			end

			lastOutput = writeLua(buffer, ";", "")
		elseif nodeType == "assignment" then
			local assignment = node
			if not assignment.targets[1] then return nil, "Error: AST: Missing target expression(s) for assignment." end
			if not assignment.values[1] then return nil, "Error: AST: Missing value(s) for assignment." end

			if isAssignmentFunctionAssignment(assignment) then
				local func = assignment.values[1]
				if nodeCb then nodeCb(func, buffer) end

				tableInsert(buffer, func.prefix)

				lastOutput = writeAlphanum(buffer, pretty, "function", lastOutput)
				lastOutput = writeLua(buffer, " ", "")

				local implicitSelfParam = (
					func.parameters[1] ~= nil
					and func.parameters[1].name == "self"
					and assignment.targets[1].type == "lookup"
					and canNodeBeName(assignment.targets[1].member)
				)

				if implicitSelfParam then
					if nodeCb then nodeCb(assignment.targets[1], buffer) end
					tableInsert(buffer, assignment.targets[1].prefix)
					local ok; ok, lastOutput = writeLookup(buffer, pretty, indent, lastOutput, assignment.targets[1],
						true, nodeCb)
					if not ok then return nil, lastOutput end
					tableInsert(buffer, assignment.targets[1].suffix)
				else
					local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, assignment.targets[1], false,
						nodeCb)
					if not ok then return nil, lastOutput end
				end

				local selfParam      = nil
				local explicitParams = func.parameters

				if implicitSelfParam then
					selfParam      = explicitParams[1]
					explicitParams = { tableUnpack(explicitParams, 2) }
				end

				local ok; ok, lastOutput = writeFunctionParametersAndBody(buffer, pretty, indent, lastOutput, func,
					explicitParams, selfParam, nodeCb)
				if not ok then return nil, lastOutput end

				tableInsert(buffer, func.suffix)
			else
				local ok; ok, lastOutput = writeCommaSeparatedList(buffer, pretty, indent, lastOutput, assignment
					.targets, false, nodeCb)
				if not ok then return nil, lastOutput end

				if pretty then lastOutput = writeLua(buffer, " ", "") end
				lastOutput = writeLua(buffer, "=", "")
				if pretty then lastOutput = writeLua(buffer, " ", "") end

				local ok; ok, lastOutput = writeCommaSeparatedList(buffer, pretty, indent, lastOutput, assignment.values,
					false, nodeCb)
				if not ok then return nil, lastOutput end

				lastOutput = writeLua(buffer, ";", "")
			end
		elseif nodeType == "if" then
			local ifNode = node
			lastOutput   = writeAlphanum(buffer, pretty, "if", lastOutput)
			if pretty then lastOutput = writeLua(buffer, " ", "") end

			local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, ifNode.condition, true, nodeCb)
			if not ok then return nil, lastOutput end

			if pretty then lastOutput = writeLua(buffer, " ", "") end
			lastOutput = writeAlphanum(buffer, pretty, "then", lastOutput)
			if nodeCb then nodeCb(ifNode.bodyTrue, buffer) end
			local prettyBody = choosePretty(ifNode.bodyTrue, pretty)
			tableInsert(buffer, ifNode.bodyTrue.prefix)
			if prettyBody then lastOutput = writeLua(buffer, "\n", "") end

			local ok; ok, lastOutput = writeStatements(buffer, prettyBody, indent + 1, lastOutput,
				ifNode.bodyTrue.statements, nodeCb)
			if not ok then return nil, lastOutput end

			local lastTrueBody              = ifNode.bodyTrue
			local suffixesForTrailingBodies = {}

			while ifNode.bodyFalse do
				lastOutput = writeIndentationIfPretty(buffer, prettyBody, indent, lastOutput)

				-- Automatically detect what looks like 'elseif'.
				if #ifNode.bodyFalse.statements == 1 and ifNode.bodyFalse.statements[1].type == "if" then
					tableInsert(buffer, lastTrueBody.suffix)
					local body = ifNode.bodyFalse

					if nodeCb then nodeCb(body, buffer) end
					tableInsert(suffixesForTrailingBodies, body.suffix)
					ifNode = body.statements[1]
					if nodeCb then nodeCb(ifNode, buffer) end
					pretty = choosePretty(ifNode, pretty)

					tableInsert(buffer, body.prefix)
					tableInsert(buffer, ifNode.prefix)
					lastOutput = writeAlphanum(buffer, prettyBody, "elseif", lastOutput)
					if pretty then lastOutput = writeLua(buffer, " ", "") end

					local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, ifNode.condition, true,
						nodeCb)
					if not ok then return nil, lastOutput end

					if pretty then lastOutput = writeLua(buffer, " ", "") end
					lastOutput = writeAlphanum(buffer, pretty, "then", lastOutput)
					if nodeCb then nodeCb(ifNode.bodyTrue, buffer) end
					prettyBody = choosePretty(ifNode.bodyTrue, pretty)
					if prettyBody then lastOutput = writeLua(buffer, "\n", "") end

					tableInsert(buffer, ifNode.bodyTrue.prefix)
					local ok; ok, lastOutput = writeStatements(buffer, prettyBody, indent + 1, lastOutput,
						ifNode.bodyTrue.statements, nodeCb)
					if not ok then return nil, lastOutput end
					tableInsert(buffer, ifNode.bodyTrue.suffix)

					lastTrueBody = ifNode
				else
					lastOutput = writeAlphanum(buffer, prettyBody, "else", lastOutput)
					if nodeCb then nodeCb(ifNode.bodyFalse, buffer) end
					prettyBody = choosePretty(ifNode.bodyFalse, pretty)
					tableInsert(buffer, ifNode.bodyFalse.prefix)
					if prettyBody then lastOutput = writeLua(buffer, "\n", "") end

					local ok; ok, lastOutput = writeStatements(buffer, prettyBody, indent + 1, lastOutput,
						ifNode.bodyFalse.statements, nodeCb)
					if not ok then return nil, lastOutput end

					tableInsert(suffixesForTrailingBodies, ifNode.bodyFalse.suffix)
					break
				end
			end

			lastOutput = writeIndentationIfPretty(buffer, prettyBody, indent, lastOutput)
			tableInsert(buffer, lastTrueBody.suffix)
			for i = #suffixesForTrailingBodies, 1, -1 do
				tableInsert(buffer, suffixesForTrailingBodies[i])
			end
			lastOutput = writeAlphanum(buffer, prettyBody, "end", lastOutput)
		elseif nodeType == "while" then
			local whileLoop = node
			lastOutput      = writeAlphanum(buffer, pretty, "while", lastOutput)
			if pretty then lastOutput = writeLua(buffer, " ", "") end

			local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, whileLoop.condition, true, nodeCb)
			if not ok then return nil, lastOutput end

			if pretty then lastOutput = writeLua(buffer, " ", "") end
			lastOutput = writeAlphanum(buffer, pretty, "do", lastOutput)

			if nodeCb then nodeCb(whileLoop.body, buffer) end
			local prettyBody = choosePretty(whileLoop.body, pretty)
			tableInsert(buffer, whileLoop.body.prefix)
			if prettyBody then lastOutput = writeLua(buffer, "\n", "") end

			local ok; ok, lastOutput = writeStatements(buffer, prettyBody, indent + 1, lastOutput,
				whileLoop.body.statements, nodeCb)
			if not ok then return nil, lastOutput end

			lastOutput = writeIndentationIfPretty(buffer, prettyBody, indent, lastOutput)
			tableInsert(buffer, whileLoop.body.suffix)
			lastOutput = writeAlphanum(buffer, prettyBody, "end", lastOutput)
		elseif nodeType == "repeat" then
			local repeatLoop = node
			lastOutput       = writeAlphanum(buffer, pretty, "repeat", lastOutput)
			if nodeCb then nodeCb(repeatLoop.body, buffer) end
			local prettyBody = choosePretty(repeatLoop.body, pretty)
			tableInsert(buffer, repeatLoop.body.prefix)
			if prettyBody then lastOutput = writeLua(buffer, "\n", "") end

			local ok; ok, lastOutput = writeStatements(buffer, prettyBody, indent + 1, lastOutput,
				repeatLoop.body.statements, nodeCb)
			if not ok then return nil, lastOutput end

			lastOutput = writeIndentationIfPretty(buffer, prettyBody, indent, lastOutput)
			tableInsert(buffer, repeatLoop.body.suffix)
			lastOutput = writeAlphanum(buffer, prettyBody, "until", lastOutput)
			if pretty then lastOutput = writeLua(buffer, " ", "") end

			local ok; ok, lastOutput = writeNode(buffer, pretty, indent, lastOutput, repeatLoop.condition, true, nodeCb)
			if not ok then return nil, lastOutput end
		elseif nodeType == "for" then
			local forLoop = node
			if not forLoop.names[1] then return nil, "Error: AST: Missing name(s) for 'for' loop." end
			if not forLoop.values[1] then return nil, "Error: AST: Missing value(s) for 'for' loop." end

			lastOutput = writeAlphanum(buffer, pretty, "for", lastOutput)
			lastOutput = writeLua(buffer, " ", "")

			local ok; ok, lastOutput = writeCommaSeparatedList(buffer, pretty, indent, lastOutput, forLoop.names, false,
				nodeCb)
			if not ok then return nil, lastOutput end

			if pretty then lastOutput = writeLua(buffer, " ", "") end

			if forLoop.kind == "numeric" then
				lastOutput = writeLua(buffer, "=", "")
			elseif forLoop.kind == "generic" then
				lastOutput = writeAlphanum(buffer, pretty, "in", lastOutput)
			else
				return nil, F("Error: Unknown 'for' loop kind '%s'.", forLoop.kind)
			end

			if pretty then lastOutput = writeLua(buffer, " ", "") end

			local ok; ok, lastOutput = writeCommaSeparatedList(buffer, pretty, indent, lastOutput, forLoop.values, false,
				nodeCb)
			if not ok then return nil, lastOutput end

			if pretty then lastOutput = writeLua(buffer, " ", "") end
			lastOutput = writeAlphanum(buffer, pretty, "do", lastOutput)
			if nodeCb then nodeCb(forLoop.body, buffer) end
			local prettyBody = choosePretty(forLoop.body, pretty)
			tableInsert(buffer, forLoop.body.prefix)
			if prettyBody then lastOutput = writeLua(buffer, "\n", "") end

			local ok; ok, lastOutput = writeStatements(buffer, prettyBody, indent + 1, lastOutput,
				forLoop.body.statements, nodeCb)
			if not ok then return nil, lastOutput end

			lastOutput = writeIndentationIfPretty(buffer, prettyBody, indent, lastOutput)
			tableInsert(buffer, forLoop.body.suffix)
			lastOutput = writeAlphanum(buffer, prettyBody, "end", lastOutput)
		else
			return false, F("Error: Unknown node type '%s'.", tostring(nodeType))
		end

		tableInsert(buffer, node.suffix)

		return true, lastOutput
	end

	-- luaString    = toLua( astNode [, prettyOuput=false, nodeCallback ] )
	-- nodeCallback = function( node, outputBuffer )
	-- Returns nil and a message on error.
	--[[local]]
	function toLua(node, pretty, nodeCb)
		assertArg1("toLua", 1, node, "table")

		local buffer = {}

		local ok, err
		if node.type == "block" then -- @Robustness: This exception isn't great. Should there be a file scope node?
			if nodeCb then nodeCb(node, buffer) end
			tableInsert(buffer, node.prefix)
			ok, err = writeStatements(buffer, choosePretty(node, pretty), 0, "", node.statements, nodeCb)
			tableInsert(buffer, node.suffix)
		else
			ok, err = writeNode(buffer, pretty, 0, "", node, true, nodeCb)
		end

		if ok then
			return tableConcat(buffer)
		else
			return nil, err
		end
	end
end

parser = {
	--
	-- Functions.
	--

	-- AST parsing.
	parse = parse,

	-- Big AST operations.
	minify = minify,

	-- Conversion.
	toLua = toLua,

	-- Cache management.
	clearCaches = clearCaches,
}

return parser



--[[!===========================================================

Copyright © 2020-2022 Marcus 'ReFreezed' Thunström

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

==============================================================]]
