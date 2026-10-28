-- Ported from openOS devfs
-- Virtual filesystem for device nodes (/dev). Mounted by kinit before /tmp.

local fs = require("filesystem")
local text = require("text")
local component = require("component")
local event = require("event")

local devfs = {}

-- Yes this prevents some ridiculous bugs
local epoch = 0
function devfs.bump()
    epoch = epoch + 1
end

function devfs.prepare(fn, name)
    return function(...)
        local res = table.pack(pcall(fn, ...))
        if res[1] then
            return table.unpack(res, 2, res.n)
        end
        return nil, tostring(res[2])
    end
end

local dcache, pcache = {}, {}
local adapters = {}
devfs.adapters = adapters

local default_adapter_dirs = { "/sys/drivers/adapters" }

local function adapter_dirs()
    local cfg = polaris and polaris.config and polaris.config["devfs.adapterDirs"]
    return type(cfg) == "table" and cfg or default_adapter_dirs
end

local adapter_api = {}

function adapter_api.toArgsPack(input, pack)
    local split = text.split(input, { "%s" }, true)
    local req = pack[1]
    local num = #split
    if num < req then return nil, "insufficient args" end
    local result = { n = num }
    for index = 1, num do
        local typename = pack[index + 1]
        local token = split[index]
        if typename == "boolean" then
            if token ~= "true" and token ~= "false" then return nil, "bad boolean value" end
            token = token == "true"
        elseif typename == "number" then
            token = tonumber(token)
            if not token then return nil, "bad number value" end
        end
        result[index] = token
    end
    return result
end

function adapter_api.createWriter(callback, ...)
    local types = table.pack(...)
    return function(input)
        local args, why = adapter_api.toArgsPack(input, types)
        if not args then return why end
        return callback(table.unpack(args, 1, args.n))
    end
end

function adapter_api.create_toggle(read, write, switch)
    return
    {
        read = read and function() return tostring(read()) end,
        write = write and function(value)
            value = text.trim(tostring(value))
            local on = value == "1" or value == "true"
            local off = value == "0" or value == "false"
            if not on and not off then
                return nil, "bad value"
            end
            if switch then
                (off and switch or write)()
            else
                write(on)
            end
        end
    }
end
-- I think links may be broken though I am unsure
function adapter_api.make_link(list, addr, prefix, bOmitZero)
    prefix = prefix or ""
    local zero = bOmitZero and "" or "0"
    local id = 0
    local name
    repeat
        name = string.format("%s%s", prefix, id == 0 and zero or tostring(id))
        id = id + 1
    until not list[name]
    list[name] = { link = addr }
end

function adapters.get(ptype)
    checkArg(1, ptype, "string")
    if dcache[ptype] == nil then
        local adapter = false
        for _, dir in ipairs(adapter_dirs()) do
            local loader = loadfile(dir .. "/" .. ptype .. ".lua", "bt", _G)
            if loader then
                local ok, loaded = pcall(loader, adapter_api)
                if ok and type(loaded) == "function" then
                    adapter = loaded
                end
                break
            end
        end
        dcache[ptype] = adapter
    end
    return dcache[ptype]
end

function adapters.proxy(addr)
    checkArg(1, addr, "string")
    local proxy = pcache[addr]
    if not proxy then
        local ok, got = pcall(component.proxy, addr)
        proxy = ok and got or nil
        if proxy then
            pcache[addr] = proxy
        end
    end
    return proxy
end

function adapters.invalidate(ptype)
    checkArg(1, ptype, "string", "nil")
    if ptype then
        dcache[ptype] = nil
    else
        dcache = {}
    end
    devfs.bump()
end

local function on_component_change(_, addr)
    if addr then
        pcache[addr] = nil
    end
    devfs.bump()
end
event.listen("component_added", on_component_change)
event.listen("component_removed", on_component_change)

local function new_node(proxy)
    return { proxy = proxy, children = {} }
end

local function array_read(array, separator)
    separator = separator or " "
    local builder = {}
    for _, value in ipairs(array) do
        table.insert(builder, tostring(value))
    end
    return table.concat(builder, separator)
end

local function child_iterator(node)
    -- a node can be a file, which has a proxy, but no children
    local listed = {}
    if node then
        if node.children then
            for name, child in pairs(node.children) do
                listed[name] = child
            end
        end
        if node.proxy and node.proxy.list then
            local list = node.proxy.list
            local dynamic = type(list) == "table" and list or list()
            for name, item in pairs(dynamic) do
                if listed[name] == nil then
                    listed[name] = item
                end
            end
        end
    end
    local availables = {}
    for name, item in pairs(listed) do
        if name:len() > 0 then
            if not item.proxy then item = new_node(item) end
            if not item.proxy.isAvailable then
                availables[name] = item
            else
                local ok, available = pcall(item.proxy.isAvailable)
                if ok and available then
                    availables[name] = item
                end
            end
        end
    end
    return pairs(availables)
end

local function get_child(node, name)
    for child_name, child in child_iterator(node) do
        if child_name == name then
            return child
        end
    end
end

local function add_child(node, name, proxy)
    if not node then
        return nil, "cannot add child"
    end

    local child = new_node(proxy)
    node.children[name] = child
    return child
end

local function findNode(api, path, bCreate)
    local segments = fs.segments(path)
    local node = api.root
    while #segments > 0 do
        local name = table.remove(segments, 1)
        local next = get_child(node, name)
        if not next then
            if bCreate then
                if not add_child(node, name) then
                    return nil, "cannot create child node"
                end
            else
                return nil, "no such file or directory"
            end
        end
        node = next or get_child(node, name)
    end
    return node
end

-- I cheat here so I dont have to manually nil things
local listing_cache = setmetatable({}, { __mode = "k" })

local inject_dynamic_pairs

local function dynamic_list(api, path, fsnode)
    local nodes, links, dirs = {}, {}, {}
    local node = findNode(api, path)
    if node then
        for name, cnode in child_iterator(node) do
            if cnode.proxy and cnode.proxy.link then
                links[name] = cnode.proxy.link
            elseif cnode.proxy and cnode.proxy.list then
                local child = { name = name, parent = fsnode }
                local child_path = path .. "/" .. name
                inject_dynamic_pairs(child, child_path, api)
                dirs[name] = child
            else
                nodes[name] = cnode
            end
        end
    end
    return nodes, links, dirs
end

inject_dynamic_pairs = function(fsnode, path, api)
    if getmetatable(fsnode) then return end
    fsnode.children = nil
    fsnode.links = nil
    setmetatable(fsnode,
        {
            __index = function(tbl, key)
                local bLinks = key == "links"
                local bChildren = key == "children"
                if not bLinks and not bChildren then return end
                local record = listing_cache[tbl]
                if not record or record.epoch ~= epoch then
                    local _, links, dirs = dynamic_list(api, path, tbl)
                    record = { epoch = epoch, dirs = dirs, links = links }
                    listing_cache[tbl] = record
                end
                return bLinks and record.links or record.dirs
            end
        })
end

function devfs.new()
    local api = { providers = {} }

    api.root = new_node({
        list = function()
            local listed = {}
            for _, provider in pairs(api.providers) do
                local ok, faces = pcall(provider)
                if ok and type(faces) == "table" then
                    for name, face in pairs(faces) do
                        if listed[name] == nil then
                            listed[name] = face
                        end
                    end
                end
            end
            return listed
        end
    })

    function api.create(path, proxy)
        checkArg(1, path, "string")
        checkArg(2, proxy, "table", "nil")
        local pwd = fs.path(path)
        local name = fs.name(path)
        if not name then return nil, "invalid devfs path" end
        local pnode, why = findNode(api, pwd, true)
        if not pnode then
            return nil, why
        end

        if get_child(pnode, name) then
            return nil, "file or directory exists"
        end

        local added = add_child(pnode, name, proxy)
        if added then
            devfs.bump()
        end
        return added
    end

    function api.remove(path)
        checkArg(1, path, "string")
        local pwd = fs.path(path)
        local name = fs.name(path)
        if not name or name:len() == 0 then
            return nil, "invalid devfs path"
        end
        local pnode = findNode(api, pwd)
        if not pnode or not pnode.children[name] then
            return nil, "no such file or directory"
        end
        pnode.children[name] = nil
        devfs.bump()
        return true
    end

    function api.define(name, fn)
        checkArg(1, name, "string")
        checkArg(2, fn, "function")
        api.providers[name] = fn
        devfs.bump()
        return true
    end

    function api.mount(path)
        checkArg(1, path, "string")
        local ok, why = fs.mount(api.proxy, path)
        if not ok then
            return nil, why
        end
        api.mountpoint = path
        return true
    end

    api.proxy = {}

    local registered = false
    function api.register(public_proxy)
        if registered then return end
        registered = true

        if rawget(public_proxy, "fsnode") then
            inject_dynamic_pairs(public_proxy.fsnode, "", api)
        end
    end

    function api.proxy.list(path)
        local nodes, links, dirs = dynamic_list(api, path, false)
        local result = {}
        for name in pairs(nodes) do table.insert(result, name) end
        for name in pairs(links) do table.insert(result, name) end
        for name in pairs(dirs) do table.insert(result, name) end
        return result
    end

    function api.proxy.isDirectory(path)
        local node = findNode(api, path)
        return node and node.proxy and node.proxy.list
    end

    function api.proxy.size(path)
        checkArg(1, path, "string")
        local node = findNode(api, path)
        if not node or not node.proxy then
            return 0
        end

        local proxy = node.proxy
        if proxy.list then return 0 end
        if proxy.size then return proxy.size() end
        if proxy.open then return 0 end
        if proxy.read then return proxy.read():len() end
        if proxy[1] ~= nil then return array_read(proxy):len() end
        return 0
    end

    function api.proxy.lastModified()
        return 0
    end

    function api.proxy.exists(path)
        checkArg(1, path, "string")
        return not not findNode(api, path)
    end

    function api.getDevice(path)
        checkArg(1, path, "string")

        local real, why = fs.realPath(path)
        if not real then return nil, why end

        real = fs.path(real) .. (fs.name(real) or "")

        local mountpoint = api.mountpoint or "/dev"
        local part, subbed = real:gsub("^" .. mountpoint:gsub("%p", "%%%0") .. "/", "")
        if subbed > 0 and part:len() > 0 then
            local node = findNode(api, part)
            if node and node.proxy then
                local device = node.proxy.device
                if device then return device end
            end
            return nil, "not a device"
        end

        return fs.get(real)
    end

    function api.proxy.open(path, mode)
        checkArg(1, path, "string")
        checkArg(2, mode, "string", "nil")

        mode = mode or "r"
        local bRead = mode:match("[ra]")
        local bWrite = mode:match("[wa]")

        if not bRead and not bWrite then
            return nil, "invalid mode"
        end

        local node, why = findNode(api, path)
        if not node then
            return nil, why
        elseif not node.proxy or node.proxy.list then
            return nil, "is a directory"
        end

        local proxy = node.proxy

        -- in case someone tries to open a link directly, refer them back to fs
        -- this is an unfortunate pathing hack due to optimizations for memory
        if proxy.link then
            return fs.open((api.mountpoint or "/dev") .. "/" .. path, mode)
        end

        -- special (but common) simple readonly cases
        if proxy[1] ~= nil then
            local array = proxy
            proxy.read = function() return array_read(array) end
        end

        if proxy.open then
            return proxy.open(mode)
        end

        if bRead and not proxy.read then
            return nil, "cannot open for read"
        elseif bWrite and not proxy.write then
            return nil, "cannot open for write"
        end

        local txtRead = bRead and proxy.read()

        if bWrite then
            return text.internal.writer(proxy.write, mode, txtRead)
        end

        return text.internal.reader(txtRead, mode)
    end

    -- as long as the fsnode hack is used, fs.isLink is not needed here
    local function checked_invoke(handle, method, ...)
        checkArg(1, handle, "table")
        checkArg(2, method, "string")
        checkArg(3, handle[method], "function", "table", "nil")
        local m = handle[method]
        if not m then
            return nil, "bad file handle"
        elseif type(m) == "table" then
            local mm = getmetatable(m)
            assert(mm and mm.__call, string.format("FILE handle [%s] method defined, but is not callable", tostring(method)))
        end
        return m(handle, ...)
    end

    function api.proxy.read(h, ...)
        return checked_invoke(h, "read", ...)
    end

    function api.proxy.close(h, ...)
        return checked_invoke(h, "close", ...)
    end

    function api.proxy.write(h, ...)
        return checked_invoke(h, "write", ...)
    end

    function api.proxy.seek(h, ...)
        return checked_invoke(h, "seek", ...)
    end

    function api.proxy.remove()
        return nil, "cannot remove file or directory"
    end

    function api.proxy.makeDirectory()
        return nil, "use create in the devfs api"
    end

    function api.proxy.setLabel()
        return nil, "cannot set label on devfs"
    end

    return api
end

local default = devfs.new()
for _, name in ipairs({ "root", "create", "remove", "proxy", "getDevice", "register", "define", "mount" }) do
    devfs[name] = default[name]
end

return devfs
