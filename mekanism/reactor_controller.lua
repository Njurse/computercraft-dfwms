-- reactor_scram.lua
-- Mekanism fission reactor SCRAM monitor for CC:Tweaked (Valhelsia 6 / 1.20.1)
-- Logic Adapter on back, wireless modem on right.

-- ── Configuration ────────────────────────────────────────────────────────────
local REACTOR_SIDE    = "back"
local MODEM_SIDE      = "right"
local REDNET_PROTOCOL = "reactor_monitor"

local CRITICAL_TEMP   = 1000   -- K  — above this triggers SCRAM
local RESUME_TEMP     = 350    -- K  — below this clears SCRAM (35% of 1000)
local SCAN_INTERVAL   = 2.0    -- seconds between polls
local FAILSAFE_TRIPS  = 2      -- consecutive SCRAMs before operator lockout

local ALARM_FILE      = "scram_alarm.dfpwm"
local ALARM_VOLUME    = 3.0    -- max range

-- ── State ─────────────────────────────────────────────────────────────────────
local scram        = false   -- true while temperature is over threshold
local failsafe     = false   -- true after FAILSAFE_TRIPS consecutive trips
local fail_count   = 0       -- consecutive SCRAM trips
local alarm_active = false   -- shared flag read by the alarm coroutine
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
local function send(msgType, body)
    if modemOpen then
        rednet.broadcast({ type = msgType, body = body, time = os.time() }, REDNET_PROTOCOL)
    end
end

local function printStatus(line)
    local ts = os.date("%H:%M:%S")
    print(string.format("[%s] %s", ts, line))
end

-- ── Alarm coroutine ───────────────────────────────────────────────────────────
-- Runs in parallel. Loops scram_alarm.dfpwm across ALL attached speakers
-- while alarm_active is true. Resets the dfpwm decoder each loop so the file
-- plays from the start cleanly. Yields properly so the reactor loop still runs.
local function alarmLoop()
    local dfpwm = require("cc.audio.dfpwm")

    while true do
        if not alarm_active then
            -- Nothing to do — yield and wait
            os.sleep(0.1)
        else
            -- Find all speakers each loop (handles hot-plug)
            local speakers = { peripheral.find("speaker") }
            if #speakers == 0 then
                printStatus("WARN: alarm_active but no speakers found!")
                os.sleep(1)
            elseif not fs.exists(ALARM_FILE) then
                printStatus("WARN: " .. ALARM_FILE .. " not found on this computer.")
                os.sleep(1)
            else
                -- One decoder per speaker per file-pass to keep state clean
                local decoders = {}
                for i = 1, #speakers do
                    decoders[i] = dfpwm.make_decoder()
                end

                for chunk in io.lines(ALARM_FILE, 16 * 1024) do
                    if not alarm_active then break end
                    for i, spk in ipairs(speakers) do
                        local ok, buf = pcall(decoders[i], chunk)
                        if ok then
                            -- Retry until buffer accepts the chunk
                            local played = false
                            local attempts = 0
                            while not played and attempts < 20 do
                                local ok2, result = pcall(spk.playAudio, buf, ALARM_VOLUME)
                                if ok2 and result then
                                    played = true
                                else
                                    os.pullEvent("speaker_audio_empty")
                                end
                                attempts = attempts + 1
                            end
                        end
                    end
                end
                -- File finished — loop will restart at top of while true
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
        -- ── Poll temperature ──────────────────────────────────────────────────
        local ok, val = pcall(reactor.getTemperature)
        if not ok or val == nil then
            printStatus("ERROR: getTemperature() failed — " .. tostring(val))
            send("ERROR", "Temperature read failed")
            alarm_active = true
            os.sleep(SCAN_INTERVAL)
        else
            temperature = val

            -- ── Evaluate SCRAM condition ──────────────────────────────────────
            if temperature > CRITICAL_TEMP then
                if not scram then
                    -- Rising edge: new trip
                    fail_count = fail_count + 1
                    printStatus(string.format(
                        "TRIP #%d — Temp %.1fK exceeds %dK", fail_count, temperature, CRITICAL_TEMP
                    ))
                    send("SCRAM_ALERT", string.format("Trip #%d at %.1fK", fail_count, temperature))
                end
                scram = true

                if fail_count >= FAILSAFE_TRIPS then
                    failsafe = true
                end

            elseif temperature < RESUME_TEMP and scram and not failsafe then
                -- Safe to clear SCRAM (only if not in failsafe)
                scram = false
                printStatus(string.format("Temp %.1fK — SCRAM cleared.", temperature))
                send("SCRAM_CLEARED", string.format("Temp %.1fK", temperature))
            end

            -- ── Act on state ──────────────────────────────────────────────────
            if failsafe then
                -- Hard lockout — SCRAM and demand operator intervention
                alarm_active = true
                local ok2, err2 = pcall(reactor.scram)
                if not ok2 then
                    printStatus("ERROR: scram() call failed — " .. tostring(err2))
                end
                printStatus("!! FAILSAFE ACTIVE !! Operator reset required.")
                printStatus(string.format(
                    "   %d consecutive trips | Current temp: %.1fK", fail_count, temperature
                ))
                send("FAILSAFE", string.format("%d trips, %.1fK", fail_count, temperature))

                -- Block here until operator presses Enter
                print("")
                print("Type  reset  and press Enter to clear failsafe:")
                local input = read()
                if input == "reset" then
                    failsafe   = false
                    scram      = false
                    fail_count = 0
                    alarm_active = false
                    printStatus("Failsafe cleared by operator. Monitoring resumed.")
                    send("FAILSAFE_RESET", "Operator reset")
                end
                -- Loop back to top without sleeping so we re-evaluate immediately

            elseif scram then
                alarm_active = true
                local ok2, err2 = pcall(reactor.scram)
                if not ok2 then
                    printStatus("ERROR: scram() call failed — " .. tostring(err2))
                end
                printStatus(string.format("SCRAM active | Temp: %.1fK | Trips: %d", temperature, fail_count))
                send("SCRAM", string.format("Temp %.1fK", temperature))
                os.sleep(SCAN_INTERVAL)

            else
                alarm_active = false
                local ok2, err2 = pcall(reactor.activate)
                if not ok2 then
                    printStatus("ERROR: activate() call failed — " .. tostring(err2))
                end
                printStatus(string.format("OK | Temp: %.1fK | Trips: %d", temperature, fail_count))
                send("STATUS", string.format("Temp %.1fK", temperature))
                os.sleep(SCAN_INTERVAL)
            end
        end
    end
end

-- ── Run both loops in parallel ────────────────────────────────────────────────
-- waitForAny: if reactorLoop returns (shouldn't) or errors, everything stops.
local ok, err = pcall(parallel.waitForAny, reactorLoop, alarmLoop)
if not ok then
    print("FATAL crash: " .. tostring(err))
end

if modemOpen then
    rednet.close(MODEM_SIDE)
end
print("Monitor stopped.")
