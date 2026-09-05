-- Polaris config at /boot/kconfig.cfg

-- Loads a file! Dangerous! However its used once and an insecure environment still
---@diagnostic disable: lowercase-global

polaris = polaris or {}
polaris.config = polaris.config or {}

local defaultPath = "/boot/polaris/kconfig.cfg"

local function loadConfig(path)
    path = path or defaultPath

    polaris.config = polaris.config or {}

    local cfg = dofile(path)

    if type(cfg) ~= "table" then
        error("Config file must return table: " .. path)
    end

    for key, value in pairs(cfg) do
        polaris.config[key] = value
    end

    return polaris.config
end

return loadConfig