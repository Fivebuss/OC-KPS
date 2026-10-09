-- /bin/colors.lua
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

for i = 0, 15 do
    local code = i < 8 and (30 + i) or (90 + i - 8)
    io.write(string.format("%-14s \27[%dm██\27[0m\n", names[i + 1], code))
end