-- /bin/flash.lua
local getopt = require("ksh.getopt")
local filesystem = require("filesystem")
local process = polaris.process

local quiet = false
local printRomFlag = false
local saveRomFlag = false

local shortSpec = "qlr"
local args = {...}

if #args < 1 and not printRomFlag then
    io.writeln("Usage: flash [-qlr] [<bios.lua>] [label]")
    io.writeln(" q: quiet mode, don't ask questions.")
    io.writeln(" l: print current contents of installed EEPROM.")
    io.writeln(" r: save the current contents of installed EEPROM to file.")
    os.exit(1)
    return
end

for opt, val in getopt(args, shortSpec) do
    if opt == "q" then
        quiet = true
    elseif opt == "l" then
        printRomFlag = true
    elseif opt == "r" then
        saveRomFlag = true
    elseif opt == "?" then
        io.writelnError("flash: unrecognized option '" .. tostring(val) .. "'")
    elseif opt == ":" then
        io.writelnError("flash: option '" .. tostring(val) .. "' requires a value")
    end
end

local component = require("component")

local chunkSize = 2048

local function chunkRead(reader)
    local count = 0
    local chunk = reader:read(chunkSize)

    while chunk do
        local ok = io.write(chunk)
        if not ok then break end

        io.flush()

        count = count + 1
        if count % 4 == 0 then
            local sig = coroutine.yield()
            if sig and process.isSignal(sig) then break end
        end

        chunk = reader:read(chunkSize)
    end
end

local function readConfirm(prompt)
    io.writeln(prompt)
    while true do
        local line, _, noNewline = io.read("l")
        if not line then return false end
        if process.isSignal(line) then return false end
        coroutine.yield()
        if line:lower():sub(1, 1) == "y" then return true end
    end
end

local function printRom()
    local eeprom = component.eeprom
    local data = eeprom.get()
    local pos = 1
    local reader = {}
    function reader:read(n)
        if pos > #data then return nil end
        local chunk = data:sub(pos, pos + n - 1)
        pos = pos + n
        return chunk
    end

    chunkRead(reader)
    return nil
end

local function saveRom()
    local eeprom = component.eeprom

    local rawArg = args[1]
    local target = console and console.stripQuotes(rawArg) or rawArg
    local fileName = console and console.resolvePath(console.currPath(), target) or target

    if not quiet then
        if filesystem.exists(fileName) then
            local ok = readConfirm("Are you sure you want to overwrite " .. fileName .. "?\nType `y` to confirm.")
            if not ok then return nil end
        end
        io.writeln("Reading EEPROM " .. eeprom.address .. ".")
    end

    local bios = eeprom.get()
    local file, reason = io.open(fileName, "wb")
    if not file then
        return nil, tostring(reason)
    end
    file:write(bios)
    file:close()

    if not quiet then
        io.writeln("All done!\nThe label is '" .. eeprom.getLabel() .. "'.")
    end

    return nil
end

local function writeRom()
    local rawArg = args[1]
    local target = console and console.stripQuotes(rawArg) or rawArg
    local fullPath = console and console.resolvePath(console.currPath(), target) or target

    if not filesystem.exists(fullPath) then
        io.writelnError("flash: " .. rawArg .. ": No such file or directory")
        return nil, "No such file or directory"
    end

    if filesystem.isDirectory(fullPath) then
        io.writelnError("flash: " .. rawArg .. ": Is a directory")
        return nil, "Is a directory"
    end

    local file, reason = io.open(fullPath, "rb")
    if not file then
        file, reason = io.open(fullPath, "rb")
    end
    if not file then
        io.writelnError("flash: " .. rawArg .. ": Cannot open file: " .. tostring(reason))
        return nil, tostring(reason)
    end

    local chunks = {}
    local chunk = file:read(2048)
    while chunk do
        chunks[#chunks + 1] = chunk
        chunk = file:read(2048)
    end
    file:close()
    local bios = table.concat(chunks)

    if not quiet then
        local ok = readConfirm("Insert the EEPROM you would like to flash.\nWhen ready to write, type `y` to confirm.")
        if not ok then return nil end
        io.writeln("Beginning to flash EEPROM.")
    end

    local eeprom = component.eeprom

    if not quiet then
        io.writeln("Flashing EEPROM " .. eeprom.address .. ".")
        io.writeln("Please do NOT power down or restart your computer during this operation!")
    end

    local result, reason = eeprom.set(bios)
    if reason then
        return nil, reason
    end

    local label = args[2]
    if not quiet and not label then
        io.writeln("Enter new label for this EEPROM. Leave input blank to leave the label unchanged.")
        local line, _, noNewline = io.read("l")
        if line and not process.isSignal(line) then
            label = line
        end
        coroutine.yield()
    end

    if label and #label > 0 then
        local result, reason = eeprom.setLabel(label)
        if reason then
            return nil, reason
        end

        if not quiet then
            io.writeln("Set label to '" .. eeprom.getLabel() .. "'.")
        end
    end

    if not quiet then
        io.writeln("All done! You can remove the EEPROM and re-insert the previous one now.")
    end

    return nil
end

local result, reason
if printRomFlag then
    result, reason = printRom()
elseif saveRomFlag then
    result, reason = saveRom()
else
    result, reason = writeRom()
end

if reason then
    io.writelnError(reason)
    os.exit(1)
    return
end
