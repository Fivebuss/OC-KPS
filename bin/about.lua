-- /bin/about.lua
-- Demo
local version = getenv("VERSION") or "Unknown"

local larpLogo = [[
'##:::'##::'######::'##::::'##:
 ##::'##::'##... ##: ##:::: ##:
 ##:'##::: ##:::..:: ##:::: ##:
 #####::::. ######:: #########:
 ##. ##::::..... ##: ##.... ##:
 ##:. ##::'##::: ##: ##:::: ##:
 ##::. ##:. ######:: ##:::: ##:
..::::..:::......:::..:::::..::
]]

io.write("\27[38;2;255;191;0m" .. larpLogo)
io.write("\27[0m===============================\n\n")
io.writeln("KPS Shell\nCopyright (c) [2026] [Fivebuss]\n")
io.writeln("Version \27[97m" .. version .. "\27[0m")
io.writeln("Written by Fivebuss for KPS")