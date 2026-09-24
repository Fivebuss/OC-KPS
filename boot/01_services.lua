-- Privileged service time
local ok, err = xpcall(function() polaris.services.boot() end, debug.traceback)
if not ok then
    polaris.log("services: boot failed: " .. tostring(err))
end