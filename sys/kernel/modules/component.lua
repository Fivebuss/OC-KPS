-- Kinda openOS's but with some custom stuff

local component = require("component")
local event = require("event")

local adding = {}
local primaries = {}

setmetatable(component, {
  __index = function(_, key)
    return component.getPrimary(key)
  end,
  __pairs = function(self)
    local parent = false
    return function(_, key)
      if parent then
        return next(primaries, key)
      else
        local k, v = next(self, key)
        if not k then
          parent = true
          return next(primaries)
        else
          return k, v
        end
      end
    end
  end
})

function component.get(address, componentType)
  checkArg(1, address, "string")
  checkArg(2, componentType, "string", "nil")
  for c in component.list(componentType, true) do
    if c:sub(1, address:len()) == address then
      return c
    end
  end
  return nil, "no such component"
end

function component.isAvailable(componentType)
  checkArg(1, componentType, "string")
  if not primaries[componentType] and not adding[componentType] then
    -- This is mostly to avoid out of memory errors preventing proxy
    -- creation cause confusion by trying to create the proxy again,
    -- causing the oom error to be thrown again.
    component.setPrimary(componentType, component.list(componentType, true)())
  end
  return primaries[componentType] ~= nil
end

function component.isPrimary(address)
  local componentType = component.type(address)
  if componentType then
    if component.isAvailable(componentType) then
      return primaries[componentType].address == address
    end
  end
  return false
end

function component.getPrimary(componentType)
  checkArg(1, componentType, "string")
  assert(component.isAvailable(componentType),
    "no primary '" .. componentType .. "' available")
  return primaries[componentType]
end

function component.setPrimary(componentType, address)
  checkArg(1, componentType, "string")
  checkArg(2, address, "string", "nil")
  if address ~= nil then
    address = component.get(address, componentType)
    assert(address, "no such component")
  end

  local wasAvailable = primaries[componentType]
  if wasAvailable and address == wasAvailable.address then
    return
  end
  local wasAdding = adding[componentType]
  if wasAdding and address == wasAdding.address then
    return
  end
  if wasAdding then
    event.cancel(wasAdding.timer)
  end
  primaries[componentType] = nil
  adding[componentType] = nil

  local primary = address and component.proxy(address) or nil
  if wasAvailable then
    computer.pushSignal("component_unavailable", componentType)
  end
  if primary then
    if wasAvailable or wasAdding then
      adding[componentType] = {
        address = address,
        proxy = primary,
        timer = event.timer(0.1, function()
          adding[componentType] = nil
          primaries[componentType] = primary
          computer.pushSignal("component_available", componentType)
        end)
      }
    else
      primaries[componentType] = primary
      computer.pushSignal("component_available", componentType)
    end
  end
end

-- Handlers

local function onComponentAdded(_, address, componentType)
  if polaris.config["debug"] then
    log("Component added: " .. componentType .. " : " .. address)
  end
  if componentType == "filesystem" then
    computer.pushSignal("filesystem_added", address, componentType)
  end
end

local function onComponentRemove(_, address, componentType)
  if polaris.config["debug"] then
    log("Component removed: " .. componentType .. " : " .. address)
  end

  if componentType == "filesystem" then
    computer.pushSignal("filesystem_removed", address, componentType)
  end

  if primaries[componentType] and primaries[componentType].address == address or
     adding[componentType] and adding[componentType].address == address
  then
    local next = component.list(componentType, true)()
    component.setPrimary(componentType, next)
  end
end

event.listen("component_added", onComponentAdded)
event.listen("component_removed", onComponentRemove)