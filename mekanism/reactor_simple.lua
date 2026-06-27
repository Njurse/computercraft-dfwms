-- reactor_scram.lua
-- Monitors a Mekanism Fission Reactor, SCRAMs at a temperature threshold,
-- and sends neatly formatted status reports over Rednet.

-- Configuration
local TEMP_THRESHOLD = 1200          -- Kelvin
local REACTOR_SIDE = "back"          -- Side the Logic Adapter is directly touching
local MODEM_SIDE = "right"           -- Side for the WIRELESS modem (for rednet broadcasts)
local REDNET_PROTOCOL = "reactor_monitor"  -- Protocol string for rednet filtering
local CHECK_INTERVAL = 1             -- Seconds between checks
local STATUS_INTERVAL = 10           -- Seconds between status broadcasts

-- Wrap the reactor logic adapter directly by side.
-- The Logic Adapter must be physically adjacent to this computer (no wired modem needed).
local reactor = peripheral.wrap(REACTOR_SIDE)
if not reactor then
    print("ERROR: No peripheral found on side '" .. REACTOR_SIDE .. "'.")
    print("Make sure the Fission Reactor Logic Adapter is touching this side of the computer.")
    return
end
if not reactor.getTemperature then
    print("ERROR: Peripheral on '" .. REACTOR_SIDE .. "' is not a Fission Reactor Logic Adapter.")
    print("peripheral type: " .. tostring(peripheral.getType(REACTOR_SIDE)))
    return
end

-- Setup wireless modem
local modemOpen = false
if MODEM_SIDE and peripheral.isPresent(MODEM_SIDE) then
    local modem = peripheral.wrap(MODEM_SIDE)
    if modem and modem.isWireless and modem.isWireless() then
        rednet.open(MODEM_SIDE)
        modemOpen = true
        print("Wireless modem opened on '" .. MODEM_SIDE .. "'.")
    else
        print("WARNING: No wireless modem on '" .. MODEM_SIDE .. "'.")
    end
else
    print("Wireless disabled.")
end

-- Helper to broadcast a message
local function sendMessage(msgType, formattedMessage, rawData)
    if modemOpen then
        local data = {
            type = msgType,
            message = formattedMessage,
            stats = rawData,          -- structured data for receivers that parse
            time = os.time()
        }
        rednet.broadcast(data, REDNET_PROTOCOL)
        print("[REDNET] " .. msgType .. " sent.")
    end
end

-- Collect all available reactor statistics
local function getReactorStats()
    local stats = {}

    -- List of method names and how to format them
    local methods = {
        getTemperature           = { label = "Temperature",     fmt = "%.1f K" },
        getFuelFilledPercentage  = { label = "Fuel Fill",       fmt = "%.1f %%" },
        getWasteFilledPercentage = { label = "Waste Fill",      fmt = "%.1f %%" },
        getBurnRate              = { label = "Burn Rate",        fmt = "%.1f mb/t" },
        getActualBurnRate        = { label = "Actual Burn Rate",fmt = "%.1f mb/t" },
        getMaxBurnRate           = { label = "Max Burn Rate",   fmt = "%.1f mb/t" },
        getStatus                = { label = "Status",          fmt = "%s" },
        getDamagePercent         = { label = "Damage",          fmt = "%.2f %%" },
        getCoolantFilledPercentage = { label = "Coolant Fill",  fmt = "%.1f %%" },
        getHeatedCoolantFilledPercentage = { label = "Heated Coolant Fill", fmt = "%.1f %%" },
    }

    for method, info in pairs(methods) do
        if reactor[method] then
            local ok, val = pcall(reactor[method], reactor)
            if ok and val ~= nil then
                -- Convert boolean to Yes/No
                if type(val) == "boolean" then
                    val = val and "Yes" or "No"
                end
                stats[method] = val
                stats[info.label] = string.format(info.fmt, val)
            else
                stats[info.label] = "N/A"
            end
        else
            stats[info.label] = "N/A"
        end
    end

    -- Build a neat, boxed status report
    local function buildReport(header)
        local lines = {}
        table.insert(lines, "")
        table.insert(lines, "=== " .. header .. " ===")

        -- Determine the longest label to align colons
        local maxLen = 0
        for label, _ in pairs(stats) do
            -- BUG FIX: skip raw method-name keys (e.g. "getTemperature")
            if type(label) == "string" and not label:match("^get") and not label:match("^is") then
                if #label > maxLen then maxLen = #label end
            end
        end

        -- Sort labels for consistent output
        local sortedLabels = {}
        for label, _ in pairs(stats) do
            if type(label) == "string" and not label:match("^get") and not label:match("^is") then
                table.insert(sortedLabels, label)
            end
        end
        table.sort(sortedLabels)

        for _, label in ipairs(sortedLabels) do
            local padding = string.rep(" ", maxLen - #label + 2)
            -- BUG FIX: was "lines.insert" (invalid), must be "table.insert"
            table.insert(lines, label .. ":" .. padding .. tostring(stats[label]))
        end

        table.insert(lines, string.rep("=", maxLen + 10))
        return table.concat(lines, "\n")
    end

    return stats, buildReport
end

-- Main loop
print("Reactor SCRAM monitor started.")
print("Threshold: " .. TEMP_THRESHOLD .. "K, Check interval: " .. CHECK_INTERVAL .. "s")
print("Press Ctrl+T to stop.")

local statusTimer = 0

while true do
    local stats, report = getReactorStats()
    -- BUG FIX: use nil as fallback instead of math.huge so a missing
    -- temperature triggers the "unformed?" warning rather than a SCRAM
    local temp = stats.getTemperature

    if temp ~= nil and temp <= TEMP_THRESHOLD then
        -- Normal operating range
        statusTimer = statusTimer + CHECK_INTERVAL
        if statusTimer >= STATUS_INTERVAL then
            local fullReport = report("Reactor Status")
            print(fullReport)
            sendMessage("STATUS", fullReport, stats)
            statusTimer = 0
        else
            -- Brief status line between full reports
            print(string.format("[%s] Temp: %.1fK | Fuel: %s | Waste: %s",
                os.date("%H:%M:%S"),
                temp,
                stats["Fuel Fill"] or "N/A",
                stats["Waste Fill"] or "N/A"
            ))
        end

    elseif temp ~= nil and temp > TEMP_THRESHOLD then
        -- Over-temperature: SCRAM
        local alertMsg = "TEMPERATURE EXCEEDED! " ..
            string.format("Temp = %.1fK (Threshold = %dK)", temp, TEMP_THRESHOLD)
        print("WARNING: " .. alertMsg)

        local scramReport = report("SCRAM TRIGGERED")
        print(scramReport)
        sendMessage("SCRAM_ALERT", scramReport, stats)

        local ok, err = pcall(reactor.scram, reactor)
        if ok then
            print("Reactor SCRAMMED successfully.")
            sendMessage("SCRAM_SUCCESS", "Reactor SCRAMMED at " .. string.format("%.1fK", temp), stats)
        else
            print("Failed to SCRAM: " .. tostring(err))
            sendMessage("SCRAM_FAILED", "SCRAM failed: " .. tostring(err), stats)
        end
        break

    else
        -- Temperature unreadable (reactor unformed, peripheral error, etc.)
        print("WARNING: Cannot read temperature. Is the reactor formed?")
        sendMessage("ERROR", "Temperature read failed. Reactor may be unformed.", { error = "no_temp" })
    end

    sleep(CHECK_INTERVAL)
end

-- Cleanup
if modemOpen then
    rednet.close(MODEM_SIDE)
end
print("Reactor monitor stopped.")
