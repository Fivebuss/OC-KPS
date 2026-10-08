-- /bin/stty.lua
-- No console driver yet but its fine. 
-- Hang on, whats that? A week later there is one? And its compatible now? Miracle, I dont even need to touch this or tty module
-- Worlds worse elseif spam. AI made this, I am not clinically insane

local args = { ... }
local tty = _G.ctty

if not tty then
    io.stderr:writeln("stty: ctty unavailable in environment!")
    os.exit(1)
    return false
end

if #args == 0 or args[1] == "-a" or args[1] == "all" then
    io.writeln(string.format(
        "resolution %dx%d;\necho=%s; line=%s; raw=%s; cursor=%s; xoff=%s;\ndisabled signals: ^C=%s, ^Z=%s, ^D=%s",
        tty.w, tty.h,
        tostring(tty.attributes.echo),
        tostring(tty.attributes.line),
        tostring(tty.attributes.raw),
        tostring(tty.attributes.cursor),
        tostring(tty.attributes.xoff),
        tostring(tty.disabled.C or false),
        tostring(tty.disabled.Z or false),
        tostring(tty.disabled.D or false)
    ))
    os.exit(0)
end

for _, arg in ipairs(args) do
    if arg == "sane" then
        tty.attributes.echo = true
        tty.attributes.line = true
        tty.attributes.raw = false
        tty.attributes.xoff = false
        tty:setCursor(true)
        tty.disabled = {}
    elseif arg == "size" then
        io.writeln(string.format("%d %d", tty.h, tty.w))
    elseif arg == "echo" then
        tty.attributes.echo = true
    elseif arg == "-echo" then
        tty.attributes.echo = false
    elseif arg == "line" then
        tty.attributes.line = true
    elseif arg == "-line" then
        tty.attributes.line = false
    elseif arg == "raw" then
        tty.attributes.raw = true
    elseif arg == "-raw" then
        tty.attributes.raw = false
    elseif arg == "cursor" then
        tty:setCursor(true)
    elseif arg == "-cursor" then
        tty:setCursor(false)
    elseif arg == "xoff" then
        tty.attributes.xoff = true
    elseif arg == "-xoff" then
        tty.attributes.xoff = false
    elseif arg == "intr" then
        tty.disabled.C = false
    elseif arg == "-intr" then
        tty.disabled.C = true
    elseif arg == "susp" then
        tty.disabled.Z = false
    elseif arg == "-susp" then
        tty.disabled.Z = true
    elseif arg == "eof" then
        tty.disabled.D = false
    elseif arg == "-eof" then
        tty.disabled.D = true
    end
end

os.exit(0)
