--- Module for getopt
-- @author Wobbo
-- Ported to MShell then KPS by Fivebuss, and long flag added

--- Iterate over all the options the user provided.
-- This function returns an iterator that can be used in the generic for that iterates over all the options the user specified when he called the program. It takes the arguments that were provided to the program, and a list of valid options as a string.
-- @tparam table args: args table
-- @tparam string options: A string with all the valid options. Options are specifid with a : after the arguments, optional options are specified with a ::
-- @tparam table longopts: A table that maps long to short flags
local function getopt(args, options, longopts)
    checkArg(1, args, "table")
    checkArg(2, options, "string")
    checkArg(3, longopts, "table", "nil")
    longopts = longopts or {}

    local current = nil
    local pos = 1

    local pendingChar, pendingVal, pendingHasVal = nil, nil, false

    local function lookup(char)
        return string.find(options, char .. ':*')
    end

    local function resolve(char)
        local i, j = lookup(char)
        if not i then
            return '?', char
        elseif j - i == 0 then
            return char        -- takes no value, ignore any --flag=value that was passed
        elseif j - i == 1 then -- required value
            if pendingHasVal then
                return char, pendingVal
            elseif not args[1] or args[1]:sub(1, 1) == '-' then
                return ':', char
            else
                return char, table.remove(args, 1)
            end
        else -- j - i == 2, optional value
            if pendingHasVal then
                return char, pendingVal
            end
            return char, (args[1] and args[1]:sub(1, 1) ~= '-' and table.remove(args, 1)) or nil
        end
    end

    return function()
        if pendingChar then
            local char = pendingChar
            pendingChar = nil
            local ret1, ret2 = resolve(char)
            pendingVal, pendingHasVal = nil, false
            return ret1, ret2
        end

        if not current or pos > #current then
            if #args > 0 and args[1]:sub(1, 2) == "--" and #args[1] > 2 then
                -- Long option: --name or --name=value
                local raw = table.remove(args, 1):sub(3)
                local name, val = raw:match("^([^=]+)=(.*)$")
                name = name or raw

                local short = longopts[name]
                if not short then
                    return '?', name
                end

                pendingHasVal = (val ~= nil)
                pendingVal = val
                return resolve(short)
            elseif #args > 0 and string.find(args[1], "^%-%w") then
                current = table.remove(args, 1):sub(2)
                pos = 1
            else
                -- No options left to process, the rest is up to the program
                return nil
            end
        end

        local char = current:sub(pos, pos)
        pos = pos + 1
        if char == '-' then
            return nil -- Stop processing by demand of user
        end
        return resolve(char)
    end
end

return getopt
