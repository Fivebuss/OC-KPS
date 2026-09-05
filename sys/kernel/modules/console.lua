local computer = require("computer")
local console = {}

function console.lookbusy()
    while true do
        computer.pullSignal(0)
    end
end

return console

