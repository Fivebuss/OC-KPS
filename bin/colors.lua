-- /bin/colors.lua
local args = {...}
local names = {
    "Black",
    "Red",
    "Green",
    "Yellow",
    "Blue",
    "Magenta",
    "Cyan",
    "White",
    "Bright Black",
    "Bright Red",
    "Bright Green",
    "Bright Yellow",
    "Bright Blue",
    "Bright Magenta",
    "Bright Cyan",
    "Bright White",
}

for _, a in ipairs(args) do
    if a == "--help" then
        io.writeln("Usage: colors")
        io.writeln("Displays the 8 foreground and background standard colors")
        io.writeln("There isn't anything else to it")
        os.exit(0)
    end
end

for i = 0, 15 do
    local code = i < 8 and (30 + i) or (90 + i - 8)
    io.write(string.format("%-14s \27[%dm██\27[0m\n", names[i + 1], code))
end