-- reactor_pocket.lua
-- Pocket computer companion for the reactor SCRAM monitor.
-- Receives status via rednet, and can send activate/scram commands back.
-- Designed for the Advanced Pocket Computer (26x20 chars, full 16 colours).

-- ── Config ────────────────────────────────────────────────────────────────────
local REDNET_PROTOCOL = "reactor_monitor"
local CMD_PROTOCOL    = "reactor_cmd"
local MODEM_SIDE      = "back"   -- built-in modem on pocket computers
local POLL_TIMEOUT    = 3.0      -- seconds before marking data as stale
local CRITICAL_TEMP   = 1000
local RESUME_TEMP     = 350

-- ── Palette: remap CC colours to a dark-theme industrial palette ──────────────
-- We only remap the slots we use, leaving others untouched.
-- Slot assignments (blit chars shown):
--   f = background black     → very dark navy
--   7 = panel/card bg        → dark slate
--   8 = border / dim text    → medium gray
--   0 = bright text / white  → near white
--   b = accent blue          → bright cyan-blue
--   9 = cyan                 → teal
--   d = green (OK)           → bright green
--   4 = yellow (warn)        → amber
--   e = red (alarm)          → bright red
--   1 = orange               → orange
local function applyPalette()
    if not term.isColour() then return end
    term.setPaletteColour(colors.black,     0x0d1117)  -- f: deep bg
    term.setPaletteColour(colors.gray,      0x1c2333)  -- 7: card bg
    term.setPaletteColour(colors.lightGray, 0x4a5568)  -- 8: muted / border
    term.setPaletteColour(colors.white,     0xe2e8f0)  -- 0: primary text
    term.setPaletteColour(colors.blue,      0x4299e1)  -- b: accent
    term.setPaletteColour(colors.cyan,      0x38b2ac)  -- 9: teal
    term.setPaletteColour(colors.green,     0x48bb78)  -- d: ok
    term.setPaletteColour(colors.yellow,    0xed8936)  -- 4: warning/amber
    term.setPaletteColour(colors.red,       0xfc4040)  -- e: alarm
    term.setPaletteColour(colors.orange,    0xf6ad55)  -- 1: orange
    term.setPaletteColour(colors.purple,    0x9f7aea)  -- a: purple accent
    term.setPaletteColour(colors.magenta,   0xf687b3)  -- 2: pink
end

-- ── Drawing primitives ────────────────────────────────────────────────────────
local W, H = 26, 20

local function bg(col)   term.setBackgroundColour(col) end
local function fg(col)   term.setTextColour(col) end
local function at(x, y)  term.setCursorPos(x, y) end

local function fill(x, y, w, col, char)
    bg(col)
    at(x, y)
    term.write(string.rep(char or " ", w))
end

local function centreText(y, text, fgCol, bgCol)
    fg(fgCol or colors.white)
    bg(bgCol or colors.black)
    local x = math.floor((W - #text) / 2) + 1
    at(x, y)
    term.write(text)
end

-- Horizontal bar: fills `w` chars, first `filled` chars in fillCol, rest in emptyCol
local function drawBar(x, y, w, fraction, fillCol, emptyCol)
    local filled = math.max(0, math.min(w, math.floor(fraction * w + 0.5)))
    bg(fillCol)
    at(x, y)
    term.write(string.rep("\x7f", filled))   -- block char
    bg(emptyCol)
    term.write(string.rep("\x7f", w - filled))
end

-- ── Colour helpers ────────────────────────────────────────────────────────────
local function tempColour(t)
    if t >= CRITICAL_TEMP then return colors.red
    elseif t >= CRITICAL_TEMP * 0.75 then return colors.yellow
    elseif t >= CRITICAL_TEMP * 0.40 then return colors.orange
    else return colors.green end
end

local function pctColour(pct, invertDanger)
    -- invertDanger: true = HIGH pct is danger (waste), false = LOW pct is danger (fuel/coolant)
    if invertDanger then
        if pct >= 0.85 then return colors.red
        elseif pct >= 0.60 then return colors.yellow
        else return colors.green end
    else
        if pct <= 0.10 then return colors.red
        elseif pct <= 0.25 then return colors.yellow
        else return colors.green end
    end
end

local function statusColour(d)
    if d.failsafe    then return colors.magenta  end
    if d.scram       then return colors.red      end
    if d.manual_hold then return colors.orange   end
    if d.active      then return colors.green    end
    return colors.yellow
end

local function statusText(d)
    if d.failsafe    then return "!! FAILSAFE !!" end
    if d.scram       then return "  SCRAMMED   "  end
    if d.manual_hold then return "  HELD/SAFE  "  end
    if d.active      then return "   ONLINE    "  end
    return "   OFFLINE   "
end

-- ── UI layout constants ───────────────────────────────────────────────────────
-- Row assignments on the 26x20 grid:
--  1     : title bar
--  2     : status pill
--  3     : temperature value + bar (2 lines)
--  5     : separator
--  6-13  : metric cards (4 bars × 2 lines each)
--  14    : separator
--  15    : burn rate line
--  16    : damage line
--  17    : separator
--  18-19 : [ACTIVATE] and [SCRAM] buttons
--  20    : footer / connection status

local function drawChrome(connected)
    -- Title bar
    bg(colors.blue) fg(colors.black)
    fill(1, 1, W, colors.blue)
    at(2, 1) term.write("\x10 REACTOR CTRL ")
    at(W-1, 1) fg(colors.white) term.write("v2")

    -- Separators
    bg(colors.gray)
    fill(1,  5, W, colors.gray, "\x8c")
    fill(1, 14, W, colors.gray, "\x8c")
    fill(1, 17, W, colors.gray, "\x8c")

    -- Button backgrounds
    bg(colors.green) fg(colors.black)
    fill(2, 18, 10, colors.green)
    at(3, 18) term.write(" ACTIVATE ")

    bg(colors.red) fg(colors.white)
    fill(15, 18, 10, colors.red)
    at(16, 18) term.write("  SCRAM   ")

    -- Footer
    bg(colors.gray) fg(colors.lightGray)
    fill(1, 20, W, colors.gray)
    at(2, 20)
    if connected then
        fg(colors.green) term.write("\x04 LIVE ")
        fg(colors.lightGray) term.write("Ctrl+T=quit")
    else
        fg(colors.yellow) term.write("\x04 WAIT ")
        fg(colors.lightGray) term.write("no signal...")
    end
end

local function drawStatus(d)
    local sc = statusColour(d)
    local st = statusText(d)
    bg(sc) fg(colors.black)
    fill(1, 2, W, sc)
    centreText(2, st, colors.black, sc)
end

local function drawTemperature(d)
    local t = d.temperature or 0
    local col = tempColour(t)
    local frac = math.min(1.0, t / CRITICAL_TEMP)
    local label = string.format("TEMP  %7.1f K", t)

    bg(colors.gray)  fg(colors.lightGray)
    fill(1, 3, W, colors.gray)
    at(2, 3) fg(col) term.write(label)

    -- temp bar spans full width
    fill(1, 4, W, colors.gray)
    drawBar(2, 4, W-2, frac, col, colors.lightGray)
end

local function drawMetricBar(y, label, pct, dangerHigh)
    local col = pctColour(pct, dangerHigh)
    local pctStr = string.format("%3d%%", math.floor(pct * 100))

    bg(colors.gray) fg(colors.lightGray)
    fill(1, y, W, colors.gray)
    at(2, y)
    fg(colors.white) term.write(label)
    fg(col)
    at(W - 3, y) term.write(pctStr)

    fill(1, y+1, W, colors.gray)
    drawBar(2, y+1, W-2, pct, col, colors.lightGray)
end

local function drawMetrics(d)
    drawMetricBar(6,  "COOLANT ", d.coolant  or 0, false)
    drawMetricBar(8,  "HTD CLT ", d.hcoolant or 0, true)
    drawMetricBar(10, "FUEL    ", d.fuel     or 0, false)
    drawMetricBar(12, "WASTE   ", d.waste    or 0, true)
end

local function drawExtras(d)
    local burn    = d.burn    or 0
    local maxburn = d.maxburn or 0
    local damage  = d.damage  or 0

    bg(colors.gray) fg(colors.lightGray)
    fill(1, 15, W, colors.gray)
    at(2, 15)
    fg(colors.white) term.write("BURN  ")
    fg(colors.cyan)
    term.write(string.format("%5.2f", burn))
    fg(colors.lightGray) term.write(" / ")
    fg(colors.white) term.write(string.format("%.2f mb/t", maxburn))

    fill(1, 16, W, colors.gray)
    at(2, 16)
    fg(colors.white) term.write("DMG   ")
    local dmgCol = pctColour(damage / 100, true)
    fg(dmgCol)
    term.write(string.format("%5.1f%%", damage))
    if damage > 0 then
        fg(colors.yellow) term.write(" \x21 INSPECT")
    end
end

local function drawAll(d, connected)
    -- Clear
    bg(colors.black) term.clear()
    drawChrome(connected)
    drawStatus(d)
    drawTemperature(d)
    drawMetrics(d)
    drawExtras(d)
    term.setCursorBlink(false)
end

-- ── Rednet setup ──────────────────────────────────────────────────────────────
local function openModem()
    if peripheral.isPresent(MODEM_SIDE) then
        local m = peripheral.wrap(MODEM_SIDE)
        if m and m.isWireless and m.isWireless() then
            rednet.open(MODEM_SIDE)
            return true
        end
    end
    -- fallback: try any modem
    for _, side in ipairs({"left","right","top","bottom","front","back"}) do
        if peripheral.isPresent(side) then
            local m = peripheral.wrap(side)
            if m and m.isWireless and m.isWireless() then
                rednet.open(side)
                return true
            end
        end
    end
    return false
end

-- ── Main ──────────────────────────────────────────────────────────────────────
applyPalette()

local modemOk = openModem()
if not modemOk then
    term.clear() at(1,1)
    print("No wireless modem found.")
    print("Advanced Pocket Computer has one")
    print("built in on the 'back' side.")
    return
end

-- Blank initial state
local data = {
    temperature = 0, coolant = 0, hcoolant = 0,
    fuel = 0, waste = 0, burn = 0, maxburn = 0,
    damage = 0, active = false, scram = false,
    manual_hold = false, failsafe = false,
}
local connected  = false
local lastUpdate = 0

-- ── Receive loop (parallel with input) ───────────────────────────────────────
local function receiveLoop()
    while true do
        local id, msg, proto = rednet.receive(REDNET_PROTOCOL, POLL_TIMEOUT)
        if id and type(msg) == "table" then
            -- Every broadcast now includes a `stats` table with flat method-name keys.
            -- Update whichever fields are present; keep last known value for the rest.
            local s = msg.stats or {}
            if s.getTemperature                    ~= nil then data.temperature = s.getTemperature                    end
            if s.getCoolantFilledPercentage        ~= nil then data.coolant     = s.getCoolantFilledPercentage        end
            if s.getHeatedCoolantFilledPercentage  ~= nil then data.hcoolant   = s.getHeatedCoolantFilledPercentage  end
            if s.getFuelFilledPercentage           ~= nil then data.fuel        = s.getFuelFilledPercentage           end
            if s.getWasteFilledPercentage          ~= nil then data.waste       = s.getWasteFilledPercentage          end
            if s.getBurnRate                       ~= nil then data.burn        = s.getBurnRate                       end
            if s.getMaxBurnRate                    ~= nil then data.maxburn     = s.getMaxBurnRate                    end
            if s.getDamagePercent                  ~= nil then data.damage      = s.getDamagePercent                  end

            -- Derive display state from message type.
            -- MANUAL_HOLD / MANUAL_SCRAM = reactor is intentionally held off.
            local t = msg.type
            data.active      = (t == "STATUS")
            data.scram       = (t == "SCRAM" or t == "SCRAM_ALERT")
            data.manual_hold = (t == "MANUAL_HOLD" or t == "MANUAL_SCRAM" or t == "SCRAM_CLEARED" or t == "FAILSAFE_RESET")
            data.failsafe    = (t == "FAILSAFE")

            connected  = true
            lastUpdate = os.clock()
            drawAll(data, connected)
        else
            -- Timeout — check staleness
            if connected and (os.clock() - lastUpdate) > POLL_TIMEOUT * 2 then
                connected = false
                drawAll(data, connected)
            end
        end
    end
end

-- Sends a command to the reactor computer (it must listen on CMD_PROTOCOL)
local function sendCmd(cmd)
    rednet.broadcast({ command = cmd }, CMD_PROTOCOL)
end

local function inputLoop()
    -- Draw initial screen
    drawAll(data, connected)
    while true do
        local ev, p1, p2, p3 = os.pullEvent()

        if ev == "key" then
            local k = p1
            if k == keys.a then sendCmd("activate")
            elseif k == keys.s then sendCmd("scram")
            elseif k == keys.r then sendCmd("reset")
            end
        elseif ev == "mouse_click" then
            local btn, mx, my = p1, p2, p3
            if btn == 1 then
                if my == 18 and mx >= 2  and mx <= 11 then sendCmd("activate") end
                if my == 18 and mx >= 15 and mx <= 24 then sendCmd("scram")    end
            end
        end
    end
end

-- ── Run ───────────────────────────────────────────────────────────────────────
local ok, err = pcall(parallel.waitForAny, receiveLoop, inputLoop)
if not ok then
    bg(colors.black) fg(colors.red)
    term.clear() at(1,1)
    print("Crash: " .. tostring(err))
end

-- Restore palette on exit
term.setTextColour(colors.white)
term.setBackgroundColour(colors.black)
term.clear() at(1,1)
rednet.close(MODEM_SIDE)
