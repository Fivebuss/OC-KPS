-- /bin/kmake
-- Builds /sys/kernel/kmodules.lua from /sys/kernel/modules/*.lua
-- and /boot/bootscripts.lua from /boot/*.lua stage 2 stuff

local filesystem = require("filesystem")
local parser     = require("luaparser")
local event      = require("event")
local getopt     = require("ksh.getopt")

local arglist    = args or {}

local doKernel   = true
local doBoot     = true
local doGc       = true
local root       = "/"
local optK       = false
local optB       = false

local shortSpec  = "kbfc"
local longSpec   = {}

for opt, val in getopt(arglist, shortSpec, longSpec) do
    if opt == "k" then
        optK = true
    elseif opt == "b" then
        optB = true
    elseif opt == "f" then
        doGc = false
    elseif opt == "c" then
    elseif opt == "?" then
        io.writelnError("kmake: unrecognized option '" .. tostring(val) .. "'")
        os.exit(1)
    end
end

if optK and not optB then
    doBoot = false
elseif optB and not optK then
    doKernel = false
end

if #arglist > 0 then
    root = arglist[1]
end

if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end

local function runGc()
    if doGc == true then
        local max = 0
        max = math.max(max, computer.freeMemory())

        for _ = 1, 40 do
            max = math.max(max, computer.freeMemory())
            event.pull(0)
        end
    end
end

if doGc == true then
    runGc()
else
    io.writeln("Skipping memory GC Trick for this run")
end

io.writeln("KPS Kmake V0.2")
local startTime = computer.uptime()
local startClock = os.clock()

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

local STAGE_SYMBOLS     = { "r", "p", "m", "w" }
local NUM_STAGES        = #STAGE_SYMBOLS

local progressBarBuffer = {}

local function progressBar(stage)
    local bar = progressBarBuffer
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

local function escape(s)
    local out = {}
    local n = 0
    local runStart = 1
    local len = #s

    for i = 1, len do
        local b = string.byte(s, i)
        local repl

        if b == 92 then
            repl = "\\\\"
        elseif b == 34 then
            repl = "\\\""
        elseif b == 10 then
            repl = "\\n"
        elseif b == 13 then
            repl = "\\r"
        elseif b == 9 then
            repl = "\\t"
        elseif b < 32 or b >= 127 then
            repl = string.format("\\%03d", b)
        end

        if repl then
            if runStart < i then
                n = n + 1
                out[n] = string.sub(s, runStart, i - 1)
            end
            n = n + 1
            out[n] = repl
            runStart = i + 1
        end
    end

    if runStart <= len then
        n = n + 1
        out[n] = string.sub(s, runStart, len)
    end

    return table.concat(out)
end

local readBuffer = {}

local function readFile(path)
    local handle, reason = io.open(path, "r")
    if not handle then return nil, reason end
    local chunks = readBuffer
    local n = 0
    while true do
        local chunk = handle:read(4096)
        if not chunk then break end
        n = n + 1
        chunks[n] = chunk
    end
    handle:close()
    local data = table.concat(chunks, "", 1, n)
    for i = 1, n do chunks[i] = nil end
    return data
end

local function buildFile(label, moddir, outfile, varname, ...)
    local skip = {}
    for i = 1, select("#", ...) do
        skip[select(i, ...)] = true
    end

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

    local out, err = io.open(outfile, "w")
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

    local src, ast, result
    for idx, f in ipairs(files) do
        local name = f:sub(1, -5)
        local path = filesystem.concat(moddir, f)
        local err

        src, err = readFile(path)
        if not src then
            out:close()
            io.write("\nkmake: cannot open " .. f .. ": " .. tostring(err) .. "\n")
            io.flush()
            os.exit(1)
        end
        items[idx].stage = 1
        updateProgressLine(items, idx, #items)

        ast, err = parser.parse(src, path)
        parser.clearCaches()
        runGc()
        src = nil
        if not ast then
            out:close()
            io.write("\nkmake: cannot parse " .. name .. ": " .. tostring(err) .. "\n")
            io.flush()
            os.exit(1)
        end
        items[idx].stage = 2
        updateProgressLine(items, idx, #items)

        parser.minify(ast)
        parser.clearCaches()
        runGc()
        result, err = parser.toLua(ast)
        parser.clearCaches()
        runGc()
        ast = nil
        if not result then
            out:close()
            io.write("\nkmake: cannot minify " .. name .. ": " .. tostring(err) .. "\n")
            io.flush()
            os.exit(1)
        end
        items[idx].stage = 3
        updateProgressLine(items, idx, #items)

        out:write(varname .. "[\"" .. name .. "\"] = \"" .. escape(result) .. "\"\n")
        result = nil
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
    io.writeln("Kmake: Started for polaris kernel v" .. polaris.version.kernel)
    local n = buildFile("Building kernel modules:", moddir, outfile, "modules", "component.lua")
    total   = total + n
end

if doBoot then
    local bootdir = filesystem.concat(root, "/boot")
    local outfile = filesystem.concat(root, "/boot/bootscripts.lua")
    io.writeln("Kmake: Started for KPS " .. polaris.version.os)
    local n = buildFile("Building boot scripts:", bootdir, outfile, "boot",
        "boot.lua", "bootscripts.lua", "bootscripts_old.lua")
    total = total + n
end

io.writeln("kmake: done (" ..
    total ..
    " total)\nfinished in " ..
    tostring(computer.uptime() - startTime) .. " seconds\nused " .. tostring(os.clock() - startClock) .. " CPU exec time")
io.flush()
