-- OC components port
local component = require("component")
local text = require("text")
local getopt = require("getopt")


local args = { ... }

local options = {
    l = false,
    all = false,
    limit = nil
}

local filters = {}

for opt, value in getopt(args, "la:n:", {
    all = "a",
    limit = "n"
}) do
    if opt == "l" then
        options.l = true
    elseif opt == "a" then
        options.all = true
    elseif opt == "n" then
        options.limit = tonumber(value)
    end
end

filters = args

local count = options.limit or math.huge

local components = {}
local padTo = 1

if #filters == 0 then
    -- Get all components if no filters are given.
    filters[1] = ""
end

for _, filter in ipairs(filters) do
    for address, name in component.list(filter) do
        if name:len() > padTo then
            padTo = name:len() + 2
        end
        components[address] = name
    end
end

padTo = padTo + 8 - padTo % 8

for address, name in pairs(components) do
    io.write(text.padRight(name, padTo) .. address .. "\n")

    if options.l then
        local proxy = component.proxy(address)
        local methodPadTo = 1
        local methods = {}

        if options.all then
            local docs = component.doc(address) or {}

            for methodName, doc in pairs(docs) do
                if methodName:len() > methodPadTo then
                    methodPadTo = methodName:len() + 2
                end

                methods[methodName] = doc
            end
        else
            for methodName, member in pairs(proxy) do
                if type(member) == "table" or type(member) == "function" then
                    if methodName:len() > methodPadTo then
                        methodPadTo = methodName:len() + 2
                    end

                    methods[methodName] =
                        component.doc(address, methodName)
                        or tostring(member)
                end
            end
        end

        local methodNames = {}

        for methodName in pairs(methods) do
            table.insert(methodNames, methodName)
        end

        table.sort(methodNames)

        methodPadTo = methodPadTo + 8 - methodPadTo % 8

        for _, methodName in ipairs(methodNames) do
            io.write(
                "  " ..
                text.padRight(methodName, methodPadTo) ..
                tostring(methods[methodName]) ..
                "\n"
            )
        end
    end

    count = count - 1
    if count <= 0 then
        break
    end
end