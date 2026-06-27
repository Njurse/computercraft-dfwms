-- reactor_scram.lua
-- Monitors a Mekanism Fission Reactor, SCRAMs at a temperature threshold,
-- and sends neatly formatted status reports over Rednet.

-- Configuration
local TEMP_THRESHOLD = 1200          -- Kelvin
local REACTOR_SIDE = "left"          -- Side where the logic adapter is
local MODEM_SIDE = "right"           -- Side for wireless modem (nil to disable)
local REDNET_CHANNEL = 42            -- Channel for broadcasting
local CHECK_INTERVAL = 1             -- Seconds between checks
local STATUS_INTERVAL = 10           -- Seconds between status broadcasts

-- Wrap the reactor peripheral
local reactor = peripheral.wrap(REACTOR_SIDE)
if not reactor then
    print("ERROR: No reactor logic adapter on side '" .. REACTOR_SIDE .. "'.")
    return
end

if not reactor.getTemperature then
    print("ERROR: Peripheral on '" .. REACTOR_SIDE .. "' is not a Fission Reactor Logic Adapter.")
    return
end

-- Setup wireless modem
local modemOpen = false
if MODEM_SIDE and peripheral.isPresent(MODEM_SIDE) then
    local modem = peripheral.wrap(MODEM_SIDE)
    if modem and modem.isWireless then
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
        rednet.broadcast(data, REDNET_CHANNEL)
        print("[REDNET] " .. msgType .. " sent.")
    end
end

-- Collect all available reactor statistics
local function getReactorStats()
    local stats = {}

    -- List of method names and how to format them
    local methods = {
        getTemperature      = { label = "Temperature",      fmt = "%.1f K" },
        getBoilEfficiency   = { label = "Boil Efficiency",  fmt = "%.1f %%" },
        getFuelFilledPercentage = { label = "Fuel Fill",    fmt = "%.1f %%" },
        getWasteFilledPercentage = { label = "Waste Fill",  fmt = "%.1f %%" },
        getBurnRate         = { label = "Burn Rate",        fmt = "%.1f mb/t" },
        getMaxBurnRate      = { label = "Max Burn Rate",    fmt = "%.1f mb/t" },
        getStatus           = { label = "Status",           fmt = "%s" },
        isFormed            = { label = "Formed",           fmt = "%s" },
        isBurning           = { label = "Burning",          fmt = "%s" },
        getActive           = { label = "Active",           fmt = "%s" },   -- alternate name
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
            if type(label) == "string" and not label:match("^get") then
                local len = #label
                if len > maxLen then maxLen = len end
            end
        end
        -- Sort labels for consistent output
        local sortedLabels = {}
        for label, _ in pairs(stats) do
            if type(label) == "string" and not label:match("^get") then
                table.insert(sortedLabels, label)
            end
        end
        table.sort(sortedLabels)

        for _, label in ipairs(sortedLabels) do
            local padding = string.rep(" ", maxLen - #label + 2)
            lines.insert(lines, label .. ":" .. padding .. stats[label])
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
    local temp = stats.getTemperature or math.huge   -- fallback to trigger if missing

    -- Display the full report on screen (once per check, but only when threshold safe)
    if temp and temp <= TEMP_THRESHOLD then
        -- Only print a short status line to avoid spam, but we'll print full report on interval
        statusTimer = statusTimer + CHECK_INTERVAL
        if statusTimer >= STATUS_INTERVAL then
            print(report("Reactor Status"))
            sendMessage("STATUS", report("Reactor Status"), stats)
            statusTimer = 0
        else
            -- Brief update
            print(string.format("[%s] Temp: %.1fK | Fuel: %s | Waste: %s",
                os.date("%H:%M:%S"),
                temp or 0,
                stats["Fuel Fill"] or "N/A",
                stats["Waste Fill"] or "N/A"
            ))
        end
    else
        -- Temperature exceeds threshold or couldn't be read
        if temp and temp > TEMP_THRESHOLD then
            local alertMsg = "⚠️ TEMPERATURE EXCEEDED! " ..
                string.format("Temp = %.1fK (Threshold = %dK)", temp, TEMP_THRESHOLD)
            print("WARNING: " .. alertMsg)

            -- Send full report as SCRAM alert
            local scramReport = report("SCRAM TRIGGERED")
            sendMessage("SCRAM_ALERT", scramReport, stats)

            -- SCRAM the reactor
            local ok, err = pcall(reactor.scram, reactor)
            if ok then
                print("✅ Reactor SCRAMMED successfully.")
                sendMessage("SCRAM_SUCCESS", "Reactor SCRAMMED at " .. string.format("%.1fK", temp), stats)
            else
                print("❌ Failed to SCRAM: " .. tostring(err))
            end
            break
        else
            -- Could not read temperature (unformed, etc.)
            print("⚠️ Cannot read temperature. Is the reactor formed?")
            sendMessage("ERROR", "Temperature read failed. Reactor may be unformed.", { error = "no_temp" })
        end
    end

    sleep(CHECK_INTERVAL)
end

-- Cleanup
if modemOpen then
    rednet.close(MODEM_SIDE)
end
print("Reactor monitor stopped.")
