-- player.lua  (Roulette1 and Roulette2)
-- ============================================================
-- Player station client.
-- This SAME script runs on both Roulette1 and Roulette2.
-- The computer's label determines which player it represents.
--
-- Responsibilities:
--   • Display "YOUR TURN" UI with highlighted menu
--   • Display "WAITING..." when idle
--   • Relay player input (shoot self / shoot opponent) to Admin
--   • Show shot results and health updates on the local monitor
-- ============================================================

local Net = require("network")
local GS  = require("game_state")
local UI  = require("ui")

-- ── Constants ──────────────────────────────────────────────────────────────
local HOST_ADMIN = "RouletteAdmin"

local MENU_ITEMS = {
    "Shoot Yourself",
    "Shoot Opponent",
}

-- ── Monitor Discovery ──────────────────────────────────────────────────────
-- Player stations have exactly one 3-wide advanced monitor.

local function findMonitor()
    local monitors = { peripheral.find("monitor") }
    for _, mon in ipairs(monitors) do
        local w, _ = mon.getSize()
        -- 3-wide monitor in CC:T is 57 characters wide at scale 0.5
        -- Accept any monitor; prefer wider ones
        if w >= 10 then
            -- Scale down a bit to get more text on the 3-wide monitor
            pcall(function() mon.setTextScale(0.5) end)
            return mon
        end
    end
    -- Fallback: first monitor
    if monitors[1] then
        pcall(function() monitors[1].setTextScale(0.5) end)
    end
    return monitors[1]
end

-- ── Menu Rendering ─────────────────────────────────────────────────────────

local function drawTurnScreen(mon, selected, playerLabel)
    if not mon then return end
    UI.clear(mon)

    local _, h = mon.getSize()
    local mid  = math.floor(h / 2)

    -- Header
    UI.writeCentered(mon, 1, "BUCKSHOT ROULETTE", UI.COLOR.HEADER)
    UI.hRule(mon, 2)

    -- YOUR TURN
    UI.writeCentered(mon, mid - 2, "YOUR TURN", UI.COLOR.SUCCESS)
    UI.hRule(mon, mid - 1)

    -- Menu options
    UI.menu(mon, mid, MENU_ITEMS, selected)
end

local function drawWaitingScreen(mon, health, myRole, round)
    if not mon then return end
    UI.clear(mon)

    local _, h = mon.getSize()
    local mid  = math.floor(h / 2)

    UI.writeCentered(mon, 1, "BUCKSHOT ROULETTE", UI.COLOR.HEADER)
    UI.hRule(mon, 2)
    UI.writeCentered(mon, mid, "WAITING...", UI.COLOR.DIM)

    if health then
        local hp = health[myRole] or GS.MAX_HEALTH
        UI.writeCentered(mon, mid + 2, "Your health:", UI.COLOR.DIM)
        UI.healthBar(mon, nil, mid + 3, hp, GS.MAX_HEALTH)
        -- Manually center the hearts
        local w, _ = mon.getSize()
        local barX = math.floor((w - GS.MAX_HEALTH) / 2) + 1
        UI.healthBar(mon, barX, mid + 3, hp, GS.MAX_HEALTH)
    end

    if round then
        UI.writeCentered(mon, h - 1, "Round " .. round, UI.COLOR.DIM)
    end
end

local function drawResultScreen(mon, result, myRole)
    if not mon then return end
    UI.clear(mon)

    local _, h = mon.getSize()
    local mid  = math.floor(h / 2)

    local isLive = (result.shell == GS.SHELL.LIVE)
    if isLive then
        local hitMe = (result.target == myRole)
        UI.writeCentered(mon, mid - 1, "LIVE ROUND!", UI.COLOR.ERROR)
        if hitMe then
            UI.writeCentered(mon, mid + 1, "YOU TOOK A HIT", UI.COLOR.WARNING)
        else
            UI.writeCentered(mon, mid + 1, "OPPONENT HIT",  UI.COLOR.SUCCESS)
        end
    else
        UI.writeCentered(mon, mid, "CLICK.", UI.COLOR.DIM)
        if result.extra_turn then
            UI.writeCentered(mon, mid + 1, "Bonus turn!", UI.COLOR.SUCCESS)
        end
    end
    sleep(2)
end

local function drawGameOverScreen(mon, winner, myRole)
    if not mon then return end
    UI.clear(mon)

    local _, h = mon.getSize()
    local mid  = math.floor(h / 2)

    if winner == myRole then
        UI.writeCentered(mon, mid - 1, "YOU WIN!", UI.COLOR.WINNER)
        UI.writeCentered(mon, mid + 1, ":D",        UI.COLOR.SUCCESS)
    else
        UI.writeCentered(mon, mid - 1, "YOU LOSE.", UI.COLOR.ERROR)
        UI.writeCentered(mon, mid + 1, "Better luck next time.", UI.COLOR.DIM)
    end
end

-- ── Input Handling ─────────────────────────────────────────────────────────

--- Block until the player makes a selection using keyboard or monitor tap.
--- Returns "self" or "opponent".
---@param mon table
---@return string
local function getPlayerInput(mon)
    local selected = 1  -- 1 = Shoot Yourself, 2 = Shoot Opponent

    drawTurnScreen(mon, selected, nil)

    while true do
        local event, arg1, arg2, arg3 = os.pullEvent()

        if event == "key" then
            if arg1 == keys.up or arg1 == keys.w then
                selected = math.max(1, selected - 1)
                drawTurnScreen(mon, selected, nil)
            elseif arg1 == keys.down or arg1 == keys.s then
                selected = math.min(#MENU_ITEMS, selected + 1)
                drawTurnScreen(mon, selected, nil)
            elseif arg1 == keys.enter or arg1 == keys.space then
                return (selected == 1) and "self" or "opponent"
            end

        elseif event == "monitor_touch" then
            -- arg1 = monitor side/name, arg2 = x, arg3 = y
            -- Calculate which menu row was tapped
            -- Menu starts at mid row — derive mid from monitor height
            local _, h = mon.getSize()
            local mid  = math.floor(h / 2)
            for i, _ in ipairs(MENU_ITEMS) do
                local row = mid + (i - 1)
                if arg3 == row then
                    selected = i
                    drawTurnScreen(mon, selected, nil)
                    sleep(0.1)  -- brief highlight before confirming
                    return (selected == 1) and "self" or "opponent"
                end
            end

        elseif event == "terminate" then
            error("Terminated by user.")
        end
    end
end

-- ── Network Message Loop ───────────────────────────────────────────────────

--- The main loop that listens for server messages and responds.
local function messageLoop(adminId, myRole, mon)
    local health  = nil
    local round   = 1
    local myTurn  = false

    -- Start in waiting state
    drawWaitingScreen(mon, nil, myRole, round)

    while true do
        if myTurn then
            -- We're responsible for input — listen on two channels simultaneously:
            -- keyboard/touch events AND network packets (in case admin resets)
            local action = nil

            -- Use parallel to listen to both input and network at once
            parallel.waitForAny(
                function()
                    -- Player input task
                    action = getPlayerInput(mon)
                end,
                function()
                    -- Network override task (e.g. game reset)
                    while true do
                        local pkt, _ = Net.receive(nil, 1)
                        if pkt then
                            if pkt.type == Net.PKT.WAITING or
                               pkt.type == Net.PKT.GAME_OVER or
                               pkt.type == Net.PKT.START_GAME then
                                -- Admin overrode our turn; bail
                                action = nil
                                return
                            end
                            if pkt.type == Net.PKT.HEALTH_UPDATE then
                                health = pkt.payload.health
                            end
                        end
                    end
                end
            )

            if action then
                -- Send action to admin
                Net.send(adminId, Net.PKT.PLAYER_ACTION, { action = action })
                myTurn = false
                drawWaitingScreen(mon, health, myRole, round)
            end

        else
            -- Waiting: listen for server packets
            local pkt, _ = Net.receive(nil, 10)

            if pkt then
                local t = pkt.type

                if t == Net.PKT.YOUR_TURN then
                    myTurn = true
                    drawTurnScreen(mon, 1, myRole)

                elseif t == Net.PKT.WAITING then
                    myTurn = false
                    drawWaitingScreen(mon, health, myRole, round)

                elseif t == Net.PKT.HEALTH_UPDATE then
                    health = pkt.payload.health
                    drawWaitingScreen(mon, health, myRole, round)

                elseif t == Net.PKT.TURN_RESULT then
                    local result = pkt.payload
                    if result.health then health = result.health end
                    drawResultScreen(mon, result, myRole)
                    drawWaitingScreen(mon, health, myRole, round)

                elseif t == Net.PKT.GAME_OVER then
                    myTurn = false
                    drawGameOverScreen(mon, pkt.payload.winner, myRole)

                elseif t == Net.PKT.START_GAME then
                    -- New game starting
                    health = nil
                    round  = 1
                    drawWaitingScreen(mon, nil, myRole, round)

                elseif t == Net.PKT.SHOW_MESSAGE then
                    if not myTurn then
                        UI.clear(mon)
                        local _, h = mon.getSize()
                        UI.writeCentered(mon, math.floor(h / 2),
                            pkt.payload.text or "", UI.COLOR.WARNING)
                    end

                elseif t == Net.PKT.PING then
                    Net.send(adminId, Net.PKT.PONG, {})
                end
            end
        end
    end
end

-- ── Ready Handshake ────────────────────────────────────────────────────────

local function waitForReadyPress(mon, adminId, label)
    UI.clear(mon)
    local _, h = mon.getSize()
    local mid  = math.floor(h / 2)

    UI.writeCentered(mon, 1,     "BUCKSHOT ROULETTE",  UI.COLOR.HEADER)
    UI.hRule(mon, 2)
    UI.writeCentered(mon, mid,   label,                UI.COLOR.TEXT)
    UI.writeCentered(mon, mid+2, "Press ENTER or tap", UI.COLOR.DIM)
    UI.writeCentered(mon, mid+3, "to ready up",        UI.COLOR.DIM)

    while true do
        local event, arg1 = os.pullEvent()
        if event == "key" and (arg1 == keys.enter or arg1 == keys.space) then
            break
        elseif event == "monitor_touch" then
            break
        end
    end

    Net.send(adminId, Net.PKT.READY, { player = Net.hostname() })
    UI.clear(mon)
    UI.writeCentered(mon, math.floor(h / 2), "READY! Waiting...", UI.COLOR.SUCCESS)
end

-- ── Main Entry Point ───────────────────────────────────────────────────────

local function main()
    -- 1. Open modem
    local ok, err = Net.open()
    if not ok then
        error("[Player] Fatal: " .. (err or "Cannot open modem."))
    end

    local label = Net.hostname()
    print("[Player] Running as: " .. label)

    -- Determine role from label
    local myRole
    if label == "Roulette1" then
        myRole = GS.PLAYER.P1
    elseif label == "Roulette2" then
        myRole = GS.PLAYER.P2
    else
        error("[Player] Unknown label '" .. label .. "'. Must be Roulette1 or Roulette2.")
    end

    -- 2. Find monitor
    local mon = findMonitor()
    if not mon then
        print("[Player] WARNING: No monitor found. Running headless (terminal only).")
    end

    -- 3. Discover admin (blocks until found)
    if mon then
        UI.waiting(mon, "Connecting...")
    end

    -- Answer discovery probes from admin while also discovering admin
    local adminId
    parallel.waitForAny(
        function()
            adminId = Net.discover(HOST_ADMIN)
        end,
        function()
            Net.answerDiscovery()
        end
    )

    print("[Player] Admin found at ID " .. tostring(adminId))

    -- 4. Ready screen
    waitForReadyPress(mon, adminId, label)

    -- 5. Wait for START_GAME before entering message loop
    local startPkt = Net.receive(Net.PKT.START_GAME, 120)
    if not startPkt then
        print("[Player] Did not receive START_GAME in time. Retrying...")
        -- Re-send ready and wait again
        Net.send(adminId, Net.PKT.READY, { player = label })
        Net.receive(Net.PKT.START_GAME, 120)
    end

    print("[Player] Game started.")

    -- 6. Main message loop
    messageLoop(adminId, myRole, mon)
end

-- ── Run with fault tolerance ───────────────────────────────────────────────
while true do
    local success, err = pcall(main)
    if not success then
        print("[Player] CRASH: " .. tostring(err))
        print("[Player] Restarting in 5 seconds...")
        sleep(5)
    end
end
