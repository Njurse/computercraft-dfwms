-- CONFIG
local MODEM_SIDE = "back"
local SCAN_INTERVAL = 5

-- STATE
local entries = {}
local offset = 1
local mon = nil
local monName = nil

-- MODEM
local modem = peripheral.wrap(MODEM_SIDE)
if not modem then error("No modem found on "..MODEM_SIDE) end

local function findMonitor()
  if not modem.getNamesRemote then return nil end

  for _, name in ipairs(modem.getNamesRemote()) do
    if peripheral.getType(name) == "monitor" then
      return name
    end
  end
  return nil
end

local function wrapMonitor()
  monName = findMonitor()
  if not monName then return nil end
  return peripheral.wrap(monName)
end

local function scan()
  entries = {}

  local names = modem.getNamesRemote and modem.getNamesRemote() or {}

  for _, name in ipairs(names) do
    local pType = peripheral.getType(name)

    -- skip monitor itself
    if pType and pType ~= "monitor" then
      local ok, methods = pcall(peripheral.getMethods, name)
      if ok and methods then
        table.insert(entries, {
          name = name,
          type = pType,
          methods = methods
        })
      end
    end
  end
end

local function clear()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  mon.setCursorPos(1,1)
end

local function draw()
  if not mon then return end

  clear()

  local w, h = mon.getSize()
  local y = 1

  mon.setTextColor(colors.cyan)
  mon.write("Peripheral Scanner")
  y = y + 1

  mon.setTextColor(colors.gray)
  mon.setCursorPos(1,y)
  mon.write("Scroll: UP / DOWN")
  y = y + 1

  local lineLimit = h - 2
  local used = 0

  for i = offset, #entries do
    local e = entries[i]
    if used >= lineLimit then break end

    mon.setTextColor(colors.yellow)
    mon.setCursorPos(1,y)
    mon.write(e.name .. " (" .. e.type .. ")")
    y = y + 1
    used = used + 1

    mon.setTextColor(colors.lightGray)

    for _, m in ipairs(e.methods) do
      if used >= lineLimit then break end
      mon.setCursorPos(2,y)
      mon.write("- "..m)
      y = y + 1
      used = used + 1
    end
  end
end

local function handleInput()
  while true do
    local _, key = os.pullEvent("key")

    if key == keys.up then
      offset = math.max(1, offset - 1)
      draw()
    elseif key == keys.down then
      offset = math.min(math.max(1, #entries), offset + 1)
      draw()
    end
  end
end

local function loop()
  while true do
    mon = wrapMonitor()
    if mon then
      mon.setTextScale(0.5)
      scan()
      draw()
    end
    sleep(SCAN_INTERVAL)
  end
end

parallel.waitForAny(loop, handleInput)
