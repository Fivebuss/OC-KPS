-- /bin/kmake
-- Builds /sys/kernel/kmodules.lua from /sys/kernel/modules/*.lua
-- and /boot/bootscripts.lua from /boot/*.lua stage 2 stuff

local filesystem = require("filesystem")

local arglist = args or {}

-- no args does both, -k builds kernel and -b builds boot scripts
local doKernel = true
local doBoot = true
local root = "/"
local i = 1
while i <= #arglist do
    local a = arglist[i]
    if a == "-k" then
        doKernel = true
        doBoot = false
    elseif a == "-b" then
        doBoot = true
        doKernel = false
    elseif a == "-c" then
        -- Does nothing right now
        if i + 1 <= #arglist then
            i = i + 1
        end
    else
        root = a
    end
    i = i + 1
end

if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end

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
        elseif b < 32 then
            out[#out + 1] = string.format("\\%03d", b)
        else
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end

local function readFile(path)
    local handle, reason = filesystem.open(path, "r")
    if not handle then
        return nil, reason
    end
    local chunks = {}
    while true do
        local chunk = handle:read(4096)
        if not chunk then break end
        chunks[#chunks + 1] = chunk
    end
    handle:close()
    return table.concat(chunks)
end

-- Creates a File
local function buildFile(moddir, outfile, varname, ...)
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

    local sources = {}
    for _, f in ipairs(files) do
        local name = f:sub(1, -5)
        local path = filesystem.concat(moddir, f)
        local src, reason = readFile(path)
        if not src then
            io.write("kmake: cannot open " .. f .. ": " .. tostring(reason) .. "\n")
            io.flush()
            os.exit(1)
        end
        sources[name] = src
    end

    local out, reason = filesystem.open(outfile, "w")
    if not out then
        io.write("kmake: cannot create " .. outfile .. ": " .. tostring(reason) .. "\n")
        io.flush()
        os.exit(1)
    end
    out:write("local " .. varname .. " = {}\n")
    for _, f in ipairs(files) do
        local modname = f:sub(1, -5)
        out:write(varname .. "[\"" .. modname .. "\"] = \"" .. escape(sources[modname]) .. "\"\n")
    end
    out:write("return " .. varname .. "\n")
    out:close()

    return #files
end

local total = 0
if doKernel then
    local moddir = filesystem.concat(root, "/sys/kernel/modules")
    local outfile = filesystem.concat(root, "/sys/kernel/kmodules.lua")
    local n = buildFile(moddir, outfile, "modules")
    io.write("kmake: wrote " .. outfile .. " (" .. n .. " modules)\n")
    total = total + n
end

if doBoot then
    local bootdir = filesystem.concat(root, "/boot")
    local outfile = filesystem.concat(root, "/boot/bootscripts.lua")
    local n = buildFile(bootdir, outfile, "boot", "boot.lua", "bootscripts.lua")
    io.write("kmake: wrote " .. outfile .. " (" .. n .. " boot scripts)\n")
    total = total + n
end

io.flush()
