-- lib/center_display.lua
-- Drives the center (Admin) Advanced Monitor.
-- All rendering is in this module; game logic is never here.

local UI = require("ui")
local GS = require("game_state")

local CenterDisplay = {}

-- ── Monitor Discovery ──────────────────────────────────────────────────────

--- Find the largest advanced monitor attached to this computer.
--- Returns peripheral handle or nil.
---@return table|nil
function CenterDisplay.findMonitor()
    local best     = nil
    local bestArea = 0

    local monitors = { peripheral.find("monitor") }
    for _, mon in ipairs(monitors) do
        if mon.isColor and mon.isColor() then
            local w, h = mon.getSize()
            local area = w * h
            if area > bestArea then
                best     = mon
                bestArea = area
            end
        end
    end

    -- Fallback: any monitor if no color one found
    if not best then
        best = peripheral.find("monitor")
    end

    if best then
        best.setTextScale(0.5)  -- scale down to fit more info on larger monitors
    end

    return best
end

-- ── Internal layout constants ──────────────────────────────────────────────

local ROW = {
    TITLE     = 1,
    HRULE1    = 2,
    P1_LABEL  = 3,
    P1_HEARTS = 4,
    HRULE2    = 5,
    P2_LABEL  = 6,
    P2_HEARTS = 7,
    HRULE3    = 8,
    ROUND     = 9,
    STATUS    = 10,
    HRULE4    = 11,
    MAG_LABEL = 12,
    MAG_SHELLS= 13,
    MSG       = 15,
}

-- ── Public Rendering ───────────────────────────────────────────────────────

--- Draw the full game HUD from a state snapshot.
---@param mon      table        monitor peripheral
---@param snapshot table        GameState.snapshot()
---@param message  string|nil   optional status message
function CenterDisplay.drawHUD(mon, snapshot, message)
    if not mon then return end
    UI.clear(mon)
    local w, h = mon.getSize()

    -- Title bar
    UI.fillRow(mon, ROW.TITLE, colors.orange)
    UI.writeCentered(mon, ROW.TITLE, "BUCKSHOT ROULETTE", colors.black, colors.orange)

    -- Dividers
    UI.hRule(mon, ROW.HRULE1)
    UI.hRule(mon, ROW.HRULE2)
    UI.hRule(mon, ROW.HRULE3)
    UI.hRule(mon, ROW.HRULE4)

    -- Player 1
    UI.writeCentered(mon, ROW.P1_LABEL, "-- PLAYER 1 --", UI.COLOR.HIGHLIGHT)
    UI.healthBar(mon,
        math.floor((w - GS.MAX_HEALTH) / 2) + 1,
        ROW.P1_HEARTS,
        snapshot.health.p1,
        GS.MAX_HEALTH
    )

    -- Player 2
    UI.writeCentered(mon, ROW.P2_LABEL, "-- PLAYER 2 --", UI.COLOR.HIGHLIGHT)
    UI.healthBar(mon,
        math.floor((w - GS.MAX_HEALTH) / 2) + 1,
        ROW.P2_HEARTS,
        snapshot.health.p2,
        GS.MAX_HEALTH
    )

    -- Round info
    local roundStr = "Round " .. snapshot.round
    UI.writeCentered(mon, ROW.ROUND, roundStr, UI.COLOR.TEXT)

    -- Current turn status
    local turnStr
    if snapshot.phase == "game_over" then
        turnStr = "GAME OVER"
    elseif snapshot.phase == "lobby" then
        turnStr = "Waiting for players..."
    elseif snapshot.phase == "loading" then
        turnStr = "Loading magazine..."
    else
        turnStr = (snapshot.current_turn == GS.PLAYER.P1)
                  and "Player 1's Turn"
                  or  "Player 2's Turn"
    end
    UI.writeCentered(mon, ROW.STATUS, turnStr,
        snapshot.phase == "game_over" and UI.COLOR.ERROR or UI.COLOR.SUCCESS)

    -- Magazine summary
    UI.writeCentered(mon, ROW.MAG_LABEL, "Magazine", UI.COLOR.DIM)
    local magStr = tostring(snapshot.round_live)  .. " Live  "
                .. tostring(snapshot.round_blank) .. " Blank  ("
                .. tostring(snapshot.mag_size)    .. " remain)"
    UI.writeCentered(mon, ROW.MAG_SHELLS, magStr, UI.COLOR.TEXT)

    -- Optional message line
    if message and #message > 0 then
        UI.writeCentered(mon, ROW.MSG, message, UI.COLOR.WARNING)
    end
end

--- Narrative screen: "X BLANK, Y LIVE" then "I INSERT THE ROUNDS..."
---@param mon        table
---@param liveCount  number
---@param blankCount number
function CenterDisplay.narrativeMagazine(mon, liveCount, blankCount)
    if not mon then return end

    -- Screen 1: shell counts
    UI.clear(mon)
    local _, h = mon.getSize()
    local mid  = math.floor(h / 2)
    UI.writeCentered(mon, mid - 2, "THIS ROUND'S AMMUNITION", UI.COLOR.HEADER)
    UI.writeCentered(mon, mid,
        tostring(blankCount) .. " BLANK   " .. tostring(liveCount) .. " LIVE",
        UI.COLOR.TEXT)
    UI.writeCentered(mon, mid + 1,
        string.rep(UI.HEART_FULL, liveCount) .. "  " ..
        string.rep("\183", blankCount),   -- interpunct for blank
        UI.COLOR.LIVE_SHELL)
    sleep(3)

    -- Screen 2: loading narrative
    UI.clear(mon)
    UI.writeCentered(mon, mid, "I INSERT THE ROUNDS", UI.COLOR.WARNING)
    UI.writeCentered(mon, mid + 1, "IN A RANDOM ORDER.", UI.COLOR.WARNING)
    sleep(2)

    -- Animated dots while loading
    for i = 1, 3 do
        UI.clear(mon)
        UI.writeCentered(mon, mid, "LOADING" .. string.rep(".", i), UI.COLOR.DIM)
        sleep(0.6)
    end
end

--- Show the shot result on the center display.
---@param mon    table
---@param result table  from GameState.applyShot
---@param snapshot table
function CenterDisplay.drawShotResult(mon, result, snapshot)
    if not mon then return end

    UI.clear(mon)
    local _, h  = mon.getSize()
    local mid   = math.floor(h / 2)
    local isLive = (result.shell == GS.SHELL.LIVE)

    -- Shell name
    local shellName = isLive and "LIVE ROUND" or "BLANK ROUND"
    UI.writeCentered(mon, mid - 3, shellName,
        isLive and UI.COLOR.LIVE_SHELL or UI.COLOR.BLANK_SHELL)

    -- Result text
    if isLive then
        local who = (result.target == GS.PLAYER.P1) and "PLAYER 1" or "PLAYER 2"
        UI.writeCentered(mon, mid - 1, who .. " TAKES A HIT!", UI.COLOR.ERROR)
    else
        UI.writeCentered(mon, mid - 1, "CLICK.", UI.COLOR.DIM)
        if result.extra_turn then
            UI.writeCentered(mon, mid, "Extra turn!", UI.COLOR.SUCCESS)
        end
    end

    -- Updated health bars
    UI.write(mon, 2, mid + 2, "P1:", UI.COLOR.HIGHLIGHT)
    UI.healthBar(mon, 5, mid + 2, snapshot.health.p1, GS.MAX_HEALTH)
    UI.write(mon, 2, mid + 3, "P2:", UI.COLOR.HIGHLIGHT)
    UI.healthBar(mon, 5, mid + 3, snapshot.health.p2, GS.MAX_HEALTH)

    sleep(2.5)
end

--- Display the game-over winner screen.
---@param mon    table
---@param winner string  "p1" or "p2"
function CenterDisplay.drawWinner(mon, winner)
    if not mon then return end
    UI.clear(mon)
    local _, h = mon.getSize()
    local mid  = math.floor(h / 2)

    local label = (winner == GS.PLAYER.P1) and "PLAYER 1" or "PLAYER 2"
    UI.writeCentered(mon, mid - 2, "GAME OVER", UI.COLOR.ERROR)
    UI.writeCentered(mon, mid,     label .. " WINS!", UI.COLOR.WINNER)
    UI.writeCentered(mon, mid + 2, "Restarting soon...", UI.COLOR.DIM)
end

--- Show a simple centered message (for errors, countdowns, etc.)
---@param mon  table
---@param msg  string
---@param fg   number|nil
function CenterDisplay.showMessage(mon, msg, fg)
    if not mon then return end
    UI.clear(mon)
    local _, h = mon.getSize()
    UI.writeCentered(mon, math.floor(h / 2), msg, fg or UI.COLOR.TEXT)
end

return CenterDisplay
