do
  local addr, invoke = computer.getBootAddress(), component.invoke

  local handle = assert(invoke(addr, "open", "/boot/boot.lua"))
  local buffer = ""

  repeat
    local data = invoke(addr, "read", handle, math.maxinteger or math.huge)
    buffer = buffer .. (data or "")
  until not data

  invoke(addr, "close", handle)

  assert(load(buffer, "=/boot/boot.lua", "bt", _G))()
end