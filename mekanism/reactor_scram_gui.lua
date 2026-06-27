-- reactor_scram.lua
-- Mekanism fission reactor SCRAM monitor for CC:Tweaked (Valhelsia 6 / 1.20.1)
-- Logic Adapter on back, wireless modem on right.
-- Terminal: 51x19 normal computer with full-screen control panel.

-- -- Configuration -------------------------------------------------------------
local REACTOR_SIDE    = "back"
local MODEM_SIDE      = "right"
local REDNET_PROTOCOL = "reactor_monitor"
local CMD_PROTOCOL    = "reactor_cmd"

local CRITICAL_TEMP   = 1000   -- K  -> above this triggers SCRAM
local RESUME_TEMP     = 350    -- K  -> below this allows clearing a temp-SCRAM
local SCAN_INTERVAL   = 2.0    -- seconds between polls
local FAILSAFE_TRIPS  = 2      -- consecutive temp-SCRAMs before operator lockout

local ALARM_FILE      = "scram_alarm.dfpwm"
local ALARM_VOLUME    = 3.0

-- -- Layout constants ----------------------------------------------------------
local W, H = term.getSize()   -- typically 51 x 19
local LOG_LINES = 5           -- scrolling log at bottom
-- Row assignments:
--   1        title bar
--   2        status banner
--   3        blank separator
--   4..12    stats grid (9 rows)
--   13       blank separator
--   14       button hint bar
--   15       blank separator
--   16..H-1  log area  (LOG_LINES rows)
--   H        bottom border / clock
local STATS_TOP   = 4
local BTN_ROW     = 14
local LOG_TOP     = 16
local LOG_BOTTOM  = H - 1

-- -- Colours -------------------------------------------------------------------
-- Falls back gracefully if the terminal is monochrome.
local function C(col)
    if term.isColour() then term.setTextColour(col) end
end
local function BG(col)
    if term.isColour() then term.setBackgroundColour(col) end
end
local function resetColour()
    if term.isColour() then
        term.setTextColour(colours.white)
        term.setBackgroundColour(colours.black)
    end
end

-- -- State ---------------------------------------------------------------------
local scram        = false
local manual_hold  = false
local failsafe     = false
local fail_count   = 0
local alarm_active = false
local temperature  = 0.0
local last_stats   = {}

-- Ring buffer for the on-screen log
local log_buf      = {}
for i = 1, LOG_BOTTOM - LOG_TOP + 1 do log_buf[i] = "" end
local log_head     = 1   -- index of oldest entry (next to be overwritten)

-- Event name used to wake the reactor loop early when state changes via UI
local UI_EVENT     = "reactor_ui_cmd"

-- -- Peripherals ---------------------------------------------------------------
local reactor = peripheral.wrap(REACTOR_SIDE)
if not reactor then
    print("FATAL: No peripheral on side '" .. REACTOR_SIDE .. "'.")
    print("Place the Fission Reactor Logic Adapter touching that side.")
    return
end
if not reactor.getTemperature then
    print("FATAL: Peripheral on '" .. REACTOR_SIDE .. "' has no getTemperature.")
    print("Actual type: " .. tostring(peripheral.getType(REACTOR_SIDE)))
    return
end

local modemOpen = false
if peripheral.isPresent(MODEM_SIDE) then
    local m = peripheral.wrap(MODEM_SIDE)
    if m and m.isWireless and m.isWireless() then
        rednet.open(MODEM_SIDE)
        modemOpen = true
    end
end

-- -- Helpers -------------------------------------------------------------------
local function collectStats()
    local s = {}
    local ok, v
    ok, v = pcall(reactor.getTemperature);            if ok then s.getTemperature              = v end
    ok, v = pcall(reactor.getStatus);                 if ok then s.getStatus                   = v end
    ok, v = pcall(reactor.getBurnRate);               if ok then s.getBurnRate                  = v end
    ok, v = pcall(reactor.getActualBurnRate);         if ok then s.getActualBurnRate            = v end
    ok, v = pcall(reactor.getMaxBurnRate);            if ok then s.getMaxBurnRate               = v end
    ok, v = pcall(reactor.getFuelFilledPercentage);   if ok then s.getFuelFilledPercentage      = v end
    ok, v = pcall(reactor.getWasteFilledPercentage);  if ok then s.getWasteFilledPercentage     = v end
    ok, v = pcall(reactor.getCoolantFilledPercentage);if ok then s.getCoolantFilledPercentage   = v end
    ok, v = pcall(reactor.getHeatedCoolantFilledPercentage)
                                                      if ok then s.getHeatedCoolantFilledPercentage = v end
    ok, v = pcall(reactor.getDamagePercent);          if ok then s.getDamagePercent             = v end
    return s
end

local function send(msgType, body, stats)
    if modemOpen then
        rednet.broadcast({
            type  = msgType,
            body  = body,
            stats = stats or {},
            time  = os.time(),
        }, REDNET_PROTOCOL)
    end
end

-- -- On-screen log -------------------------------------------------------------
local function logPush(line)
    local ts = os.date("%H:%M:%S")
    local entry = string.format("[%s] %s", ts, line)
    -- Truncate to screen width
    if #entry > W then entry = entry:sub(1, W) end
    log_buf[log_head] = entry
    log_head = (log_head % #log_buf) + 1
end

-- -- Drawing -------------------------------------------------------------------
local function writeAt(x, y, text)
    term.setCursorPos(x, y)
    term.write(text)
end

local function fillRow(y, char, fg, bg)
    char = char or " "
    if fg then C(fg) end
    if bg then BG(bg) end
    term.setCursorPos(1, y)
    term.write(string.rep(char, W))
end

local function centreAt(y, text, fg, bg)
    if fg then C(fg) end
    if bg then BG(bg) end
    local x = math.floor((W - #text) / 2) + 1
    term.setCursorPos(x, y)
    term.write(text)
end

-- Render a labelled stat cell: "Label  value"
-- col is the left pixel of the cell, row is the y
local function statCell(col, row, label, value, valColour)
    resetColour()
    term.setCursorPos(col, row)
    C(colours.lightGrey)
    term.write(label .. " ")
    C(valColour or colours.white)
    term.write(value)
    -- pad to clear old chars (cells are 25 wide each, two per row)
    local used = #label + 1 + #value
    local cellW = math.floor(W / 2)
    if used < cellW then term.write(string.rep(" ", cellW - used)) end
end

-- Determine banner colour/text from current state
local function bannerInfo()
    if failsafe then
        return "!! FAILSAFE - MANUAL RESET REQUIRED !!",
               colours.white, colours.red
    elseif scram then
        return string.format("SCRAM - OVER TEMP (trip %d/%d)", fail_count, FAILSAFE_TRIPS),
               colours.black, colours.orange
    elseif manual_hold then
        return "HOLD - AWAITING ACTIVATE COMMAND",
               colours.black, colours.yellow
    else
        return "REACTOR ONLINE - NORMAL OPERATION",
               colours.black, colours.lime
    end
end

local function pct(v)
    if v == nil then return "---" end
    return string.format("%.1f%%", v * 100)
end

local function drawPanel()
    term.clear()

    -- Row 1: title
    fillRow(1, " ", colours.black, colours.blue)
    centreAt(1, "FISSION REACTOR CONTROL", colours.white, colours.blue)

    -- Row 2: status banner
    local btext, bfg, bbg = bannerInfo()
    fillRow(2, " ", bfg, bbg)
    centreAt(2, btext, bfg, bbg)

    -- Row 3: separator
    resetColour()
    fillRow(3, "-", colours.grey, colours.black)

    -- -- Stats grid ------------------------------------------------------------
    -- Two columns, 9 rows (rows 4-12)
    local s = last_stats
    local tempK    = s.getTemperature or 0
    local tempCol  = tempK > CRITICAL_TEMP and colours.red
                  or tempK > CRITICAL_TEMP * 0.8 and colours.orange
                  or colours.lime

    local half = math.floor(W / 2) + 1   -- left col of right cell

    local function row(r, lbl1, val1, col1, lbl2, val2, col2)
        statCell(1,    STATS_TOP + r - 1, lbl1, tostring(val1), col1)
        if lbl2 then
            statCell(half, STATS_TOP + r - 1, lbl2, tostring(val2), col2)
        end
    end

    local reactorOn  = s.getStatus
    local statusStr  = reactorOn == true and "ACTIVE" or reactorOn == false and "OFFLINE" or "---"
    local statusCol  = reactorOn == true and colours.lime or colours.red

    local dmg        = s.getDamagePercent
    local dmgStr     = dmg ~= nil and string.format("%.1f%%", dmg) or "---"
    local dmgCol     = dmg and dmg > 0.5 and colours.red
                    or dmg and dmg > 0.1 and colours.orange
                    or colours.lime

    local burnActual = s.getActualBurnRate
    local burnMax    = s.getMaxBurnRate
    local burnStr    = burnActual ~= nil and string.format("%.2f mB/t", burnActual) or "---"
    local burnMax_s  = burnMax    ~= nil and string.format("%.2f mB/t", burnMax)    or "---"

    row(1, "Status:",  statusStr,                                statusCol,
           "Damage:",  dmgStr,                                   dmgCol)
    row(2, "Temp:",    tempK > 0 and string.format("%.1fK", tempK) or "---", tempCol,
           "Trips:",   string.format("%d / %d", fail_count, FAILSAFE_TRIPS), colours.white)
    row(3, "Burn Rt:", burnStr,                                  colours.white,
           "Max Burn:",burnMax_s,                                colours.white)
    row(4, "Fuel:",    pct(s.getFuelFilledPercentage),           colours.white,
           "Waste:",   pct(s.getWasteFilledPercentage),          colours.white)
    row(5, "Coolant:", pct(s.getCoolantFilledPercentage),        colours.white,
           "Hot Cool:",pct(s.getHeatedCoolantFilledPercentage),  colours.white)

    -- Row 9: config reminder
    resetColour()
    C(colours.grey)
    writeAt(1, STATS_TOP + 5,
        string.format("Crit: %dK  Resume: %dK  Interval: %.1fs",
            CRITICAL_TEMP, RESUME_TEMP, SCAN_INTERVAL))

    -- Row 13: separator
    resetColour()
    fillRow(13, "-", colours.grey, colours.black)

    -- Row 14: button hints
    resetColour()
    fillRow(BTN_ROW, " ", colours.black, colours.black)
    term.setCursorPos(1, BTN_ROW)

    local function btn(key, label, fg, bg)
        BG(bg or colours.grey)
        C(fg or colours.white)
        term.write(" [" .. key .. "] " .. label .. " ")
        resetColour()
        term.write("  ")
    end

    if failsafe then
        btn("R", "RESET FAILSAFE", colours.white, colours.red)
    elseif scram then
        -- Nothing the operator can do locally until temp drops; show info
        C(colours.orange)
        term.write(" Cooling down... temp-SCRAM clears at " .. RESUME_TEMP .. "K ")
        resetColour()
    elseif manual_hold then
        btn("A", "ACTIVATE", colours.black, colours.lime)
        btn("S", "SCRAM",    colours.white, colours.red)
    else
        btn("S", "SCRAM",    colours.white, colours.red)
    end

    -- Row 15: separator
    resetColour()
    fillRow(15, "-", colours.grey, colours.black)

    -- Rows 16..H-1: rolling log
    local logLen = #log_buf
    for i = 0, logLen - 1 do
        local idx  = ((log_head - 1 + i) % logLen) + 1
        local line = log_buf[idx] or ""
        resetColour()
        C(colours.lightGrey)
        term.setCursorPos(1, LOG_TOP + i)
        term.clearLine()
        term.write(line)
    end

    -- Row H: clock + modem indicator
    fillRow(H, " ", colours.black, colours.grey)
    C(colours.black)
    BG(colours.grey)
    writeAt(1, H, os.date(" %H:%M:%S"))
    local modStr = modemOpen and "  Rednet: ON " or "  Rednet: OFF"
    writeAt(W - #modStr + 1, H, modStr)

    resetColour()
    term.setCursorPos(1, H)   -- park cursor out of the way
end

-- -- Alarm coroutine -----------------------------------------------------------
local function alarmLoop()
    local dfpwm = require("cc.audio.dfpwm")
    while true do
        if not alarm_active then
            os.sleep(0.1)
        else
            local speakers = { peripheral.find("speaker") }
            if #speakers == 0 or not fs.exists(ALARM_FILE) then
                os.sleep(1)
            else
                local decoders = {}
                for i = 1, #speakers do decoders[i] = dfpwm.make_decoder() end
                for chunk in io.lines(ALARM_FILE, 16 * 1024) do
                    if not alarm_active then break end
                    for i, spk in ipairs(speakers) do
                        local ok, buf = pcall(decoders[i], chunk)
                        if ok then
                            local attempts = 0
                            while attempts < 20 do
                                local ok2, result = pcall(spk.playAudio, buf, ALARM_VOLUME)
                                if ok2 and result then break end
                                os.pullEvent("speaker_audio_empty")
                                attempts = attempts + 1
                            end
                        end
                    end
                end
            end
        end
    end
end

-- -- Reactor logic (runs every SCAN_INTERVAL or when woken by UI_EVENT) --------
local function reactorLoop()
    logPush("Reactor monitor started.")
    logPush(string.format("Crit: %dK | Resume: %dK | Failsafe after %d trips",
        CRITICAL_TEMP, RESUME_TEMP, FAILSAFE_TRIPS))

    while true do
        local ok, stats = pcall(collectStats)
        if not ok or not stats then
            logPush("ERROR: stat collection failed - " .. tostring(stats))
            send("ERROR", "Stat collection failed", {})
            alarm_active = true
        else
            last_stats  = stats
            temperature = stats.getTemperature or 0

            -- Detect external SCRAM
            local reactorOn = stats.getStatus
            if reactorOn == false and not scram and not manual_hold and not failsafe then
                manual_hold = true
                logPush("External SCRAM detected - awaiting activate.")
                send("MANUAL_SCRAM", "External SCRAM detected", stats)
            end

            -- Evaluate temperature
            if temperature > CRITICAL_TEMP then
                if not scram then
                    fail_count = fail_count + 1
                    logPush(string.format("TRIP #%d - Temp %.1fK exceeds %dK",
                        fail_count, temperature, CRITICAL_TEMP))
                end
                scram = true
                if fail_count >= FAILSAFE_TRIPS then
                    if not failsafe then
                        logPush(string.format("FAILSAFE engaged after %d trips!", fail_count))
                        send("FAILSAFE", string.format("%d trips, %.1fK", fail_count, temperature), stats)
                    end
                    failsafe = true
                end

            elseif temperature < RESUME_TEMP and scram and not failsafe then
                scram       = false
                manual_hold = true
                logPush(string.format("Temp %.1fK - SCRAM cleared. Awaiting activate.", temperature))
                send("SCRAM_CLEARED", string.format("Temp %.1fK, awaiting activate", temperature), stats)
            end

            -- Act on state
            if failsafe then
                -- Alarm + hold. Operator must press R or send remote reset.
                alarm_active = true
                pcall(reactor.scram)
                send("FAILSAFE", string.format("%d trips, %.1fK", fail_count, temperature), stats)

            elseif scram then
                -- Over-temp SCRAM: ALARM sounds while reactor is too hot
                alarm_active = true
                pcall(reactor.scram)
                send("SCRAM", string.format("Temp %.1fK", temperature), stats)

            elseif manual_hold then
                -- Silent hold; waiting for operator activate
                alarm_active = false
                pcall(reactor.scram)
                send("MANUAL_HOLD", string.format("Temp %.1fK", temperature), stats)

            else
                alarm_active = false
                pcall(reactor.activate)
                send("STATUS", string.format("Temp %.1fK", temperature), stats)
            end
        end

        drawPanel()

        -- Sleep for SCAN_INTERVAL but wake early if a UI_EVENT fires
        local timer = os.startTimer(SCAN_INTERVAL)
        while true do
            local ev, p1 = os.pullEvent()
            if ev == "timer" and p1 == timer then break end
            if ev == UI_EVENT then break end
        end
    end
end

-- -- Local keyboard input handler ----------------------------------------------
-- Runs in parallel; posts UI_EVENT to wake reactorLoop immediately after a cmd.
local function inputLoop()
    while true do
        local _, key = os.pullEvent("key")

        if key == keys.s then
            -- SCRAM
            if not failsafe then
                manual_hold  = true
                alarm_active = false
                pcall(reactor.scram)
                logPush("Manual SCRAM by local operator.")
                send("MANUAL_SCRAM", "Local operator SCRAM", {})
                os.queueEvent(UI_EVENT)
            end

        elseif key == keys.a then
            -- ACTIVATE
            if failsafe then
                logPush("ACTIVATE rejected: failsafe active - press R to reset first.")
            elseif scram then
                logPush("ACTIVATE rejected: temp-SCRAM active - wait for cooldown.")
            elseif manual_hold then
                manual_hold  = false
                alarm_active = false
                pcall(reactor.activate)
                logPush("Reactor activated by local operator.")
                send("STATUS", "Local operator activate", last_stats)
                os.queueEvent(UI_EVENT)
            end

        elseif key == keys.r then
            -- RESET FAILSAFE
            if failsafe then
                failsafe     = false
                scram        = false
                manual_hold  = true   -- still require explicit activate
                fail_count   = 0
                alarm_active = false
                logPush("Failsafe cleared by local operator. Press A to activate.")
                send("FAILSAFE_RESET", "Local operator reset - awaiting activate", {})
                os.queueEvent(UI_EVENT)
            else
                logPush("RESET ignored: not in failsafe.")
            end
        end
    end
end

-- -- Remote command listener ----------------------------------------------------
local function commandLoop()
    if not modemOpen then return end
    while true do
        local id, msg = rednet.receive(CMD_PROTOCOL, 60)
        if id and type(msg) == "table" and type(msg.command) == "string" then
            local cmd = msg.command
            logPush("CMD from #" .. id .. ": " .. cmd)

            if cmd == "activate" then
                if failsafe then
                    logPush("CMD REJECTED: failsafe active - reset first.")
                elseif scram then
                    logPush("CMD REJECTED: temp-SCRAM active - wait for cooldown.")
                else
                    manual_hold  = false
                    alarm_active = false
                    pcall(reactor.activate)
                    logPush("Reactor activated by remote #" .. id)
                    local s = collectStats()
                    send("STATUS", "Remote activate by #" .. id, s)
                    os.queueEvent(UI_EVENT)
                end

            elseif cmd == "scram" then
                manual_hold  = true
                pcall(reactor.scram)
                logPush("Remote SCRAM from #" .. id)
                send("MANUAL_SCRAM", "Remote SCRAM by #" .. id, {})
                os.queueEvent(UI_EVENT)

            elseif cmd == "reset" then
                if failsafe then
                    failsafe     = false
                    scram        = false
                    manual_hold  = true
                    fail_count   = 0
                    alarm_active = false
                    logPush("Failsafe cleared remotely by #" .. id)
                    send("FAILSAFE_RESET", "Remote reset by #" .. id, {})
                    os.queueEvent(UI_EVENT)
                else
                    logPush("CMD: reset ignored (not in failsafe)")
                end
            end
        end
    end
end

-- -- Run -----------------------------------------------------------------------
term.clear()
term.setCursorPos(1, 1)
local ok, err = pcall(parallel.waitForAny,
    reactorLoop, alarmLoop, inputLoop, commandLoop)

-- Restore terminal on exit
term.clear()
term.setCursorPos(1, 1)
resetColour()
if not ok then
    print("FATAL crash: " .. tostring(err))
end
if modemOpen then rednet.close(MODEM_SIDE) end
print("Monitor stopped.")
