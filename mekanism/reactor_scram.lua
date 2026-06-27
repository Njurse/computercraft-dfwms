-- reactor_scram.lua
-- Mekanism fission reactor SCRAM monitor for CC:Tweaked (Valhelsia 6 / 1.20.1)
-- Logic Adapter on back, wireless modem on right.

-- ── Configuration ─────────────────────────────────────────────────────────────
local REACTOR_SIDE    = "back"
local MODEM_SIDE      = "right"
local REDNET_PROTOCOL = "reactor_monitor"
local CMD_PROTOCOL    = "reactor_cmd"

local CRITICAL_TEMP   = 1000   -- K  → above this triggers SCRAM
local RESUME_TEMP     = 350    -- K  → below this allows clearing a temp-SCRAM
local SCAN_INTERVAL   = 2.0    -- seconds between polls
local FAILSAFE_TRIPS  = 2      -- consecutive temp-SCRAMs before operator lockout

local ALARM_FILE      = "scram_alarm.dfpwm"
local ALARM_VOLUME    = 3.0

-- ── State ─────────────────────────────────────────────────────────────────────
-- scram:       reactor must be kept off due to over-temperature
-- manual_hold: reactor was scrammed manually (button/redstone/remote) and must
--              NOT auto-restart until an explicit "activate" command is received
-- failsafe:    two consecutive temp-trips → operator must reset locally or remotely
local scram        = false
local manual_hold  = false
local failsafe     = false
local fail_count   = 0
local alarm_active = false
local temperature  = 0.0

-- ── Peripherals ───────────────────────────────────────────────────────────────
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
    else
        print("WARN: Peripheral on '" .. MODEM_SIDE .. "' is not a wireless modem. Rednet disabled.")
    end
else
    print("WARN: No modem on '" .. MODEM_SIDE .. "'. Rednet disabled.")
end

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function printStatus(line)
    local ts = os.date("%H:%M:%S")
    print(string.format("[%s] %s", ts, line))
end

-- Collect all reactor stats with explicit direct calls.
-- Each method is called normally (no dynamic dispatch, no self argument)
-- so CC:Tweaked peripheral wrappers work correctly.
local function collectStats()
    local s = {}

    local ok, v

    ok, v = pcall(reactor.getTemperature)
    if ok then s.getTemperature = v end

    ok, v = pcall(reactor.getStatus)
    if ok then s.getStatus = v end

    ok, v = pcall(reactor.getBurnRate)
    if ok then s.getBurnRate = v end

    ok, v = pcall(reactor.getActualBurnRate)
    if ok then s.getActualBurnRate = v end

    ok, v = pcall(reactor.getMaxBurnRate)
    if ok then s.getMaxBurnRate = v end

    ok, v = pcall(reactor.getFuelFilledPercentage)
    if ok then s.getFuelFilledPercentage = v end

    ok, v = pcall(reactor.getWasteFilledPercentage)
    if ok then s.getWasteFilledPercentage = v end

    ok, v = pcall(reactor.getCoolantFilledPercentage)
    if ok then s.getCoolantFilledPercentage = v end

    ok, v = pcall(reactor.getHeatedCoolantFilledPercentage)
    if ok then s.getHeatedCoolantFilledPercentage = v end

    ok, v = pcall(reactor.getDamagePercent)
    if ok then s.getDamagePercent = v end

    return s
end

local function send(msgType, body, stats)
    if modemOpen then
        rednet.broadcast({
            type  = msgType,
            body  = body,
            stats = stats or {},   -- always present → pocket app reads from here
            time  = os.time(),
        }, REDNET_PROTOCOL)
    end
end

-- ── Alarm coroutine ───────────────────────────────────────────────────────────
local function alarmLoop()
    local dfpwm = require("cc.audio.dfpwm")
    while true do
        if not alarm_active then
            os.sleep(0.1)
        else
            local speakers = { peripheral.find("speaker") }
            if #speakers == 0 then
                printStatus("WARN: alarm_active but no speakers found!")
                os.sleep(1)
            elseif not fs.exists(ALARM_FILE) then
                printStatus("WARN: " .. ALARM_FILE .. " not found.")
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

-- ── Reactor control loop ──────────────────────────────────────────────────────
local function reactorLoop()
    printStatus("Reactor monitor started.")
    printStatus(string.format(
        "Critical: %dK | Resume: %dK | Failsafe after %d trips | Interval: %.1fs",
        CRITICAL_TEMP, RESUME_TEMP, FAILSAFE_TRIPS, SCAN_INTERVAL
    ))
    printStatus("Press Ctrl+T to stop.")

    while true do
        -- ── Collect all stats in one shot ─────────────────────────────────────
        local ok, stats = pcall(collectStats)
        if not ok or not stats then
            printStatus("ERROR: stat collection failed — " .. tostring(stats))
            send("ERROR", "Stat collection failed", {})
            os.sleep(SCAN_INTERVAL)
        else
            temperature = stats.getTemperature or 0

            -- ── Detect manual SCRAM (reactor went offline without us doing it) ─
            -- getStatus() returns true when the reactor is actively burning.
            -- If we didn't command a SCRAM but the reactor is now off, something
            -- external scrammed it — treat it as a manual hold.
            local reactorOn = stats.getStatus
            if reactorOn == false and not scram and not manual_hold and not failsafe then
                manual_hold = true
                printStatus("External SCRAM detected — manual reactivation required.")
                send("MANUAL_SCRAM", "External SCRAM detected", stats)
            end

            -- ── Evaluate over-temperature ──────────────────────────────────────
            if temperature > CRITICAL_TEMP then
                if not scram then
                    fail_count = fail_count + 1
                    printStatus(string.format(
                        "TRIP #%d — Temp %.1fK exceeds %dK", fail_count, temperature, CRITICAL_TEMP
                    ))
                end
                scram = true
                if fail_count >= FAILSAFE_TRIPS then
                    failsafe = true
                end

            elseif temperature < RESUME_TEMP and scram and not failsafe then
                -- Temperature safe — clear the temp-SCRAM but still require
                -- explicit activate to restart (manual_hold logic handles this)
                scram = false
                manual_hold = true   -- don't auto-restart; wait for operator
                printStatus(string.format("Temp %.1fK — SCRAM cleared. Awaiting activate.", temperature))
                send("SCRAM_CLEARED", string.format("Temp %.1fK, awaiting activate", temperature), stats)
            end

            -- ── Act on state ───────────────────────────────────────────────────
            if failsafe then
                -- Failsafe: alarm sounds, reactor held off, operator must reset
                alarm_active = true
                pcall(reactor.scram)
                printStatus(string.format(
                    "!! FAILSAFE !! %d trips | Temp: %.1fK | Type 'reset' to clear:",
                    fail_count, temperature
                ))
                send("FAILSAFE", string.format("%d trips, %.1fK", fail_count, temperature), stats)

                -- Block until local operator types reset
                local input = read()
                if input == "reset" then
                    failsafe     = false
                    scram        = false
                    manual_hold  = true   -- still require explicit activate
                    fail_count   = 0
                    alarm_active = false
                    printStatus("Failsafe cleared by operator. Send 'activate' to restart.")
                    send("FAILSAFE_RESET", "Operator reset — awaiting activate", stats)
                end

            elseif scram then
                -- Over-temperature SCRAM: silent, reactor held off
                alarm_active = false
                pcall(reactor.scram)
                printStatus(string.format(
                    "SCRAM | Temp: %.1fK | Trips: %d", temperature, fail_count
                ))
                send("SCRAM", string.format("Temp %.1fK", temperature), stats)
                os.sleep(SCAN_INTERVAL)

            elseif manual_hold then
                -- Reactor was stopped externally or after a temp-SCRAM cleared.
                -- Hold it off silently and wait for an explicit activate command.
                alarm_active = false
                pcall(reactor.scram)
                printStatus(string.format(
                    "HOLD | Temp: %.1fK | Awaiting manual activate", temperature
                ))
                send("MANUAL_HOLD", string.format("Temp %.1fK", temperature), stats)
                os.sleep(SCAN_INTERVAL)

            else
                alarm_active = false
                pcall(reactor.activate)
                printStatus(string.format(
                    "OK | Temp: %.1fK | Trips: %d", temperature, fail_count
                ))
                send("STATUS", string.format("Temp %.1fK", temperature), stats)
                os.sleep(SCAN_INTERVAL)
            end
        end
    end
end

-- ── Remote command listener ────────────────────────────────────────────────────
local function commandLoop()
    if not modemOpen then return end
    while true do
        local id, msg = rednet.receive(CMD_PROTOCOL, 60)
        if id and type(msg) == "table" and type(msg.command) == "string" then
            local cmd = msg.command
            printStatus("CMD from #" .. id .. ": " .. cmd)

            if cmd == "activate" then
                if failsafe then
                    printStatus("CMD REJECTED: failsafe active — reset first.")
                elseif scram then
                    printStatus("CMD REJECTED: temp-SCRAM active — wait for cooldown.")
                else
                    manual_hold  = false
                    alarm_active = false
                    pcall(reactor.activate)
                    printStatus("Reactor activated by remote #" .. id)
                    local s = collectStats()
                    send("STATUS", "Remote activate by #" .. id, s)
                end

            elseif cmd == "scram" then
                manual_hold  = true
                pcall(reactor.scram)
                printStatus("Remote SCRAM from #" .. id)
                send("MANUAL_SCRAM", "Remote SCRAM by #" .. id, {})

            elseif cmd == "reset" then
                if failsafe then
                    failsafe     = false
                    scram        = false
                    manual_hold  = true   -- still require explicit activate
                    fail_count   = 0
                    alarm_active = false
                    printStatus("Failsafe cleared remotely by #" .. id)
                    send("FAILSAFE_RESET", "Remote reset by #" .. id, {})
                else
                    printStatus("CMD: reset ignored (not in failsafe)")
                end
            end
        end
    end
end

-- ── Run ───────────────────────────────────────────────────────────────────────
local ok, err = pcall(parallel.waitForAny, reactorLoop, alarmLoop, commandLoop)
if not ok then
    print("FATAL crash: " .. tostring(err))
end
if modemOpen then rednet.close(MODEM_SIDE) end
print("Monitor stopped.")
