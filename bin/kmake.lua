-- /bin/kmake
-- Builds /sys/kernel/kmodules.lua from /sys/kernel/modules/*.lua
-- and /boot/bootscripts.lua from /boot/*.lua stage 2 stuff

local filesystem = require("filesystem")
local parser     = require("luaparser")

local arglist    = args or {}

-- no args does both, -k builds kernel and -b builds boot scripts
local doKernel   = true
local doBoot     = true
local root       = "/"
local i          = 1
while i <= #arglist do
    local a = arglist[i]
    if a == "-k" then
        doKernel = true
        doBoot   = false
    elseif a == "-b" then
        doBoot   = true
        doKernel = false
    elseif a == "-c" then
        -- reserved, consumes next arg
        if i + 1 <= #arglist then i = i + 1 end
    else
        root = a
    end
    i = i + 1
end

if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end

-- Look how fancy I am

local ESC = "\27"

local function cursorUp(n)
    if n > 0 then io.write(ESC .. "[" .. n .. "A\r") end
end

local function cursorDown(n)
    if n > 0 then io.write(ESC .. "[" .. n .. "B\r") end
end

local function rewriteLine(text)
    io.write("\r" .. ESC .. "[K" .. text)
end

local STAGE_SYMBOLS = { "r", "p", "m", "w" }
local NUM_STAGES    = #STAGE_SYMBOLS

local function progressBar(stage)
    local bar = {}
    for j = 1, NUM_STAGES do
        bar[j] = (j <= stage) and STAGE_SYMBOLS[j] or " "
    end
    return "[" .. table.concat(bar) .. "]"
end

local function printProgressBlock(items)
    for _, item in ipairs(items) do
        io.write("  " .. item.name .. ": " .. progressBar(item.stage) .. "\n")
    end
    io.flush()
end

local function updateProgressLine(items, idx, total)
    local linesUp = total - idx + 1
    cursorUp(linesUp)
    rewriteLine("  " .. items[idx].name .. ": " .. progressBar(items[idx].stage))
    cursorDown(linesUp - 1)
    io.write("\n")
    io.flush()
end

-- Makes it embeddable into a file as a string
local function escape(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        local b = c:byte()
        if c == "\\" then
            out[#out + 1] = "\\\\"
        elseif c == "\"" then
            out[#out + 1] = "\\\""
        elseif c == "\n" then
            out[#out + 1] = "\\n"
        elseif c == "\r" then
            out[#out + 1] = "\\r"
        elseif c == "\t" then
            out[#out + 1] = "\\t"
        elseif b < 32 or b >= 127 then
            out[#out + 1] = string.format("\\%03d", b)
        else
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end

local function readFile(path)
    local handle, reason = filesystem.open(path, "r")
    if not handle then return nil, reason end
    local chunks = {}
    while true do
        local chunk = handle:read(4096)
        if not chunk then break end
        chunks[#chunks + 1] = chunk
    end
    handle:close()
    return table.concat(chunks)
end

-- Makes a file
local function buildFile(label, moddir, outfile, varname, ...)
    local skip = {}
    for i = 1, select("#", ...) do
        skip[select(i, ...)] = true
    end

    -- What do we have here?
    local files = {}
    for f in filesystem.list(moddir) do
        if f:sub(-4) == ".lua" and not skip[f] then
            local path = filesystem.concat(moddir, f)
            if not filesystem.isDirectory(path) then
                files[#files + 1] = f
            end
        end
    end
    table.sort(files)

    local out, err = filesystem.open(outfile, "w")
    if not out then
        io.write("kmake: cannot create " .. outfile .. ": " .. tostring(err) .. "\n")
        io.flush()
        os.exit(1)
    end
    out:write("local " .. varname .. " = {}\n")

    io.write(label .. "\n")
    local items = {}
    for _, f in ipairs(files) do
        items[#items + 1] = { name = f:sub(1, -5), stage = 0 }
    end
    printProgressBlock(items)

    -- read parse minify write
    for idx, f in ipairs(files) do
        local name = f:sub(1, -5)
        local path = filesystem.concat(moddir, f)
        local err

        local src
        src, err = readFile(path)
        if not src then
            out:close()
            io.write("\nkmake: cannot open " .. f .. ": " .. tostring(err) .. "\n")
            io.flush()
            os.exit(1)
        end
        items[idx].stage = 1
        updateProgressLine(items, idx, #items)

        -- Thanks dumbluaparser
        local ast
        ast, err = parser.parse(src, path)
        if not ast then
            out:close()
            io.write("\nkmake: cannot parse " .. name .. ": " .. tostring(err) .. "\n")
            io.flush()
            os.exit(1)
        end
        items[idx].stage = 2
        updateProgressLine(items, idx, #items)

        -- And for minifying
        parser.minify(ast)
        local result
        result, err = parser.toLua(ast)
        if not result then
            out:close()
            io.write("\nkmake: cannot minify " .. name .. ": " .. tostring(err) .. "\n")
            io.flush()
            os.exit(1)
        end
        items[idx].stage = 3
        updateProgressLine(items, idx, #items)

        -- Write it
        out:write(varname .. "[\"" .. name .. "\"] = \"" .. escape(result) .. "\"\n")
        items[idx].stage = 4
        updateProgressLine(items, idx, #items)
    end

    out:write("return " .. varname .. "\n")
    out:close()

    io.write("  wrote " .. outfile .. " (" .. #files .. " files)\n")
    io.flush()

    return #files
end

local total = 0

if doKernel then
    local moddir  = filesystem.concat(root, "/sys/kernel/modules")
    local outfile = filesystem.concat(root, "/sys/kernel/kmodules.lua")
    local n       = buildFile("Building kernel modules:", moddir, outfile, "modules", "component.lua")
    total         = total + n
end

if doBoot then
    local bootdir = filesystem.concat(root, "/boot")
    local outfile = filesystem.concat(root, "/boot/bootscripts.lua")
    local n = buildFile("Building boot scripts:", bootdir, outfile, "boot",
        "boot.lua", "bootscripts.lua", "bootscripts_old.lua")
    total = total + n
end

io.write("kmake: done (" .. total .. " total)\n")
io.flush()
