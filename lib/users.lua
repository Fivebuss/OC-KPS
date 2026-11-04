-- /lib/users.lua
-- Funny user db thing

local DEBUG = polaris.config["debug"] or false

local function log(message)
    if DEBUG then
        polaris.log(message)
    end
end

local filesystem = require("filesystem")
local M = {}

local DB_PATH = "/etc/users"

local function load()
    local byName, byUid = {}, {}
    if not filesystem.exists(DB_PATH) then
        return byName, byUid
    end

    local f, reason = filesystem.open(DB_PATH, "r")
    if not f then
        return byName, byUid
    end

    -- If you have more than like 1 user what are you doing
    local content = ""
    repeat
        local chunk, err = f:read(1024)
        if chunk then
            content = content .. chunk
        end
    until not chunk
    f:close()

    for line in content:gmatch("[^\r\n]+") do
        local name, uid, ts = line:match("^([^:]+):(%d+):([%d%.]+)$")

        if name then
            uid = tonumber(uid)
            ts = tonumber(ts)

            byName[name] = {
                uid = uid,
                created = ts
            }

            byUid[uid] = name
        end
    end

    return byName, byUid
end

-- this is harder then it looks
local function save(byName)
    local f, reason = filesystem.open(DB_PATH, "w")
    if not f then
        log("users: failed to open /etc/users for writing: " .. tostring(reason))
        return false
    end

    local list = {}
    for name, info in pairs(byName) do
        list[#list + 1] = { name = name, info = info }
    end
    table.sort(list, function(a, b) return a.info.uid < b.info.uid end)

    for _, entry in ipairs(list) do
        f:write(
            entry.name .. ":" ..
            tostring(entry.info.uid) .. ":" ..
            tostring(entry.info.created) .. "\n"
        )
    end
    f:close()
    return true
end

function M.lookup(username)
    checkArg(1, username, "string")
    local byName = load()
    local entry = byName[username]
    if not entry then return nil, "no such user: " .. username end
    return entry.uid
end

function M.name(uid)
    checkArg(1, uid, "number")
    local _, byUid = load()
    return byUid[uid]
end

function M.exists(username)
    checkArg(1, username, "string")
    return M.lookup(username) ~= nil
end

-- irritating
function M.add(username)
    checkArg(1, username, "string")
    if not username:match("^[a-z][a-z0-9_%-]*$") then
        log("users: invalid username format")
        return nil, "invalid username"
    end

    local byName, byUid = load()
    if byName[username] then
        log("users: user '" .. username .. "' already exists")
        return nil, "user exists"
    end

    local nextUid = 1
    for uid in pairs(byUid) do
        if uid >= nextUid then nextUid = uid + 1 end
    end

    byName[username] = { uid = nextUid, created = os.time() }
    if not save(byName) then
        return nil, "failed to save user database"
    end

    local home = "/home/" .. username
    if not filesystem.isDirectory(home) then
        local success, err = filesystem.makeDirectory(home)
        if not success then
            log("users: failed to create home directory: " .. tostring(err))
        end
    end

    log("users: successfully added user '" .. username .. "' with UID " .. nextUid)
    return nextUid
end


function M.remove(username)
    checkArg(1, username, "string")

    local byName = load()
    local entry = byName[username]

    if not entry then
        log("users: no such user '" .. username .. "'")
        return nil, "no such user"
    end

    if entry.uid == 0 or username == "root" then
        log("users: refusing to remove root user")
        return nil, "cannot remove root user"
    end

    byName[username] = nil

    if not save(byName) then
        return nil, "failed to save user database"
    end

    log("users: successfully removed user '" .. username .. "'")
    return true
end


function M.list()
    local byName, _ = load()
    local out = {}
    for name, info in pairs(byName) do
        out[#out + 1] = { uid = info.uid, name = name, created = info.created }
    end
    table.sort(out, function(a, b) return a.uid < b.uid end)
    return out
end

return M
