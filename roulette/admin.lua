-- admin.lua  (RouletteAdmin)
-- ============================================================
-- Authoritative game controller for Buckshot Roulette.
-- This is the ONLY computer that owns game state.
--
-- Responsibilities:
--   • Discover all peer computers by hostname
--   • Drive the center Advanced Monitor
--   • Manage the magazine (logical + physical)
--   • Coordinate the Motor Controller for drill targeting
--   • Run the full game state machine
--   • Relay turn info and results to player computers
-- ============================================================

-- ── Libraries ──────────────────────────────────────────────────────────────
local Net    = require("network")
local GS     = require("game_state")
local Inv    = require("inventory")
local CD     = require("center_display")
local UI     = require("ui")

-- ── Debug Configuration ────────────────────────────────────────────────────
local DEBUG_SINGLE_PLAYER = false  -- true = only one player needed to start

-- ── Hostname constants ─────────────────────────────────────────────────────
local HOST_P1    = "Roulette1"
local HOST_P2    = "Roulette2"
local HOST_MOTOR = "RouletteMotorCtrl"

-- ── Motor Control Helpers ──────────────────────────────────────────────────
-- These send commands to RouletteMotorCtrl over Rednet.

local function aimAt(state, target)
    Net.send(state.ids.motorCtrl, Net.PKT.AIM, { target = target })
    -- Wait for acknowledgement (with timeout)
    local pkt = Net.receive(Net.PKT.MOTOR_DONE, 5)
    if not pkt then
        print("[Admin] WARNING: Motor controller did not acknowledge AIM in time.")
    end
end

local function fire(state, rpm)
    Net.send(state.ids.motorCtrl, Net.PKT.FIRE, { rpm = rpm or 0 })
    local pkt = Net.receive(Net.PKT.MOTOR_DONE, 8)
    if not pkt then
        print("[Admin] WARNING: Motor controller did not acknowledge FIRE in time.")
    end
end

-- ── Networking Broadcast Helpers ───────────────────────────────────────────

local function broadcastHealth(state)
    local snap = GS.snapshot(state)
    Net.send(state.ids.p1, Net.PKT.HEALTH_UPDATE, snap)
    Net.send(state.ids.p2, Net.PKT.HEALTH_UPDATE, snap)
end

local function sendTurnNotice(state)
    -- Tell the active player it is their turn
    local activeId  = (state.current_turn == GS.PLAYER.P1) and state.ids.p1 or state.ids.p2
    local waitingId = (state.current_turn == GS.PLAYER.P1) and state.ids.p2 or state.ids.p1
    Net.send(activeId,  Net.PKT.YOUR_TURN, { turn = state.current_turn })
    Net.send(waitingId, Net.PKT.WAITING,   { turn = state.current_turn })
end

local function broadcastMessage(state, text)
    Net.send(state.ids.p1, Net.PKT.SHOW_MESSAGE, { text = text })
    Net.send(state.ids.p2, Net.PKT.SHOW_MESSAGE, { text = text })
end

-- ── Peripheral Discovery ───────────────────────────────────────────────────

--- Find and validate all peripherals this computer needs.
--- Returns a table of handles or errors if critical ones are missing.
local function discoverPeripherals()
    local perifs = {
        monitor  = nil,
        roles    = nil,   -- Inv.ROLE table
    }

    -- Center monitor (advanced, largest)
    perifs.monitor = CD.findMonitor()
    if not perifs.monitor then
        print("[Admin] WARNING: No advanced monitor found. Center display disabled.")
    else
        print("[Admin] Center monitor found.")
    end

    -- Inventories
    local roles, err = Inv.discoverInventories()
    if err then
        print("[Admin] WARNING: Inventory discovery: " .. err)
        print("[Admin] Running in software-only mode (no physical item movement).")
        perifs.roles = {}
    else
        perifs.roles = roles
    end

    return perifs
end

-- ── Lobby Phase ────────────────────────────────────────────────────────────

--- Wait until both (or one in debug mode) players are ready.
local function lobbyPhase(state, mon)
    CD.showMessage(mon, "Waiting for players...", UI.COLOR.DIM)
    print("[Admin] Lobby: waiting for players to press READY.")

    local needed = DEBUG_SINGLE_PLAYER and 1 or 2

    while true do
        -- Check if already ready enough
        local readyCount = (state.ready.p1 and 1 or 0) + (state.ready.p2 and 1 or 0)
        if readyCount >= needed then break end

        -- Wait for a READY packet (5 second timeout then redraw)
        local pkt, _ = Net.receive(Net.PKT.READY, 5)
        if pkt then
            if pkt.sender == HOST_P1 then
                state.ready.p1 = true
                print("[Admin] Player 1 is ready.")
            elseif pkt.sender == HOST_P2 then
                state.ready.p2 = true
                print("[Admin] Player 2 is ready.")
            end

            local msg = "P1:" .. (state.ready.p1 and "READY" or "waiting")
                     .. "  P2:" .. (state.ready.p2 and "READY" or "waiting")
            CD.showMessage(mon, msg, UI.COLOR.DIM)
        end
    end

    print("[Admin] All players ready. Starting game.")
    Net.send(state.ids.p1, Net.PKT.START_GAME, {})
    if not DEBUG_SINGLE_PLAYER then
        Net.send(state.ids.p2, Net.PKT.START_GAME, {})
    end
end

-- ── Magazine Loading Phase ─────────────────────────────────────────────────

--- Generate and physically load the magazine.
local function loadingPhase(state, perifs)
    state.phase = "loading"

    -- Generate shell order
    local shells, liveCount, blankCount = GS.generateMagazine()
    state.magazine    = shells
    state.round_live  = liveCount
    state.round_blank = blankCount

    print(string.format("[Admin] Magazine: %d live, %d blank (%d total)",
        liveCount, blankCount, #shells))

    -- Narrative on center monitor
    CD.narrativeMagazine(perifs.monitor, liveCount, blankCount)

    -- Physical loading
    if next(perifs.roles) ~= nil then
        -- First clear the magazine inventory of leftover shells
        Inv.clearMagazine(perifs.roles)

        local ok, err = Inv.loadMagazine(perifs.roles, shells, GS.SHELL_ITEMS)
        if not ok then
            print("[Admin] WARNING: Physical load failed: " .. (err or "unknown"))
        else
            print("[Admin] Magazine physically loaded.")
        end
    else
        print("[Admin] Skipping physical load (no inventories configured).")
    end

    -- Brief pause before play
    sleep(1)
    state.phase = "playing"
end

-- ── Turn Phase ─────────────────────────────────────────────────────────────

--- Run one complete turn: notify player, wait for action, resolve shot.
--- Returns false if the game ended, true to continue.
local function runTurn(state, perifs)
    local mon = perifs.monitor

    -- Announce turn
    sendTurnNotice(state)
    CD.drawHUD(mon, GS.snapshot(state))

    print("[Admin] Waiting for action from " .. state.current_turn .. "...")

    -- Wait for player action (no timeout — game cannot continue without it)
    local pkt = nil
    while not pkt do
        local candidate, _ = Net.receive(Net.PKT.PLAYER_ACTION, 30)
        if candidate then
            -- Validate: only accept from the player whose turn it is
            local expectedSender = (state.current_turn == GS.PLAYER.P1)
                                   and HOST_P1 or HOST_P2
            if candidate.sender == expectedSender then
                pkt = candidate
            else
                print("[Admin] Ignoring action from " .. (candidate.sender or "?")
                      .. " (not their turn).")
            end
        else
            -- Timeout: re-send turn notice in case client missed it
            print("[Admin] Action timeout, re-notifying players.")
            sendTurnNotice(state)
        end
    end

    local action = pkt.payload.action  -- "self" or "opponent"
    print("[Admin] Action received: " .. tostring(action))

    -- Pop shell
    local shell = GS.popShell(state)
    if not shell then
        print("[Admin] Magazine empty during turn (unexpected). Reloading.")
        return true  -- trigger reload
    end

    -- Physically move the popped shell from MAGAZINE to CHAMBER drawer
    if next(perifs.roles) ~= nil then
        local shellItem = GS.SHELL_ITEMS[shell]
        local ok, err = Inv.loadChamber(perifs.roles, shellItem)
        if not ok then
            print("[Admin] WARNING: loadChamber failed: " .. tostring(err))
        end
    end

    -- Aim the drill
    local targetPlayer = (action == "self") and state.current_turn
                         or (state.current_turn == GS.PLAYER.P1 and GS.PLAYER.P2
                                                                  or GS.PLAYER.P1)
    aimAt(state, targetPlayer)

    -- Show "firing" message
    CD.showMessage(mon, "FIRING...", UI.COLOR.WARNING)
    sleep(0.5)

    -- Fire the drill
    local isLive = (shell == GS.SHELL.LIVE)
    fire(state, nil)  -- motor_ctrl handles RPM constants

    -- Apply game logic
    local result = GS.applyShot(state, action, shell)
    broadcastHealth(state)

    -- Show result on center display
    CD.drawShotResult(mon, result, GS.snapshot(state))

    -- Broadcast result to clients
    local resultPayload = {
        shell      = shell,
        action     = action,
        damage     = result.damage,
        killed     = result.killed,
        extra_turn = result.extra_turn,
        next_turn  = result.next_turn,
        health     = { p1 = state.health.p1, p2 = state.health.p2 },
    }
    Net.send(state.ids.p1, Net.PKT.TURN_RESULT, resultPayload)
    Net.send(state.ids.p2, Net.PKT.TURN_RESULT, resultPayload)

    -- Clear the chamber drawer now that the shot has resolved
    if next(perifs.roles) ~= nil then
        Inv.clearChamber(perifs.roles)
    end

    -- Check for game over
    if state.phase == "game_over" then
        return false
    end

    -- If extra turn, current_turn was kept by applyShot
    return true
end

-- ── Game Over Phase ────────────────────────────────────────────────────────

local function gameOverPhase(state, perifs)
    local mon = perifs.monitor
    local winner = state.winner or GS.PLAYER.P1

    print("[Admin] Game over. Winner: " .. winner)
    CD.drawWinner(mon, winner)

    Net.send(state.ids.p1, Net.PKT.GAME_OVER, { winner = winner })
    Net.send(state.ids.p2, Net.PKT.GAME_OVER, { winner = winner })

    sleep(8)
end

-- ── Main Entry Point ───────────────────────────────────────────────────────

local function main()
    -- 1. Open modem
    local ok, err = Net.open()
    if not ok then
        error("[Admin] Fatal: " .. (err or "Cannot open modem."))
    end

    print("[Admin] Computer: " .. Net.hostname())
    print("[Admin] Discovering peers...")

    -- 2. Discover peers (blocks until all are found)
    local idMotor = Net.discover(HOST_MOTOR)
    local idP1    = Net.discover(HOST_P1)
    local idP2    = DEBUG_SINGLE_PLAYER and -1 or Net.discover(HOST_P2)

    -- 3. Discover peripherals
    local perifs = discoverPeripherals()

    -- 4. Build initial game state
    local state = GS.new()
    state.ids.p1        = idP1
    state.ids.p2        = idP2
    state.ids.motorCtrl = idMotor

    print("[Admin] Ready. IDs: P1=" .. idP1
          .. " P2=" .. tostring(idP2)
          .. " Motor=" .. idMotor)

    -- 5. Game loop — runs indefinitely until interrupted
    while true do
        -- Reset state for a fresh game
        state.health       = { p1 = GS.MAX_HEALTH, p2 = GS.MAX_HEALTH }
        state.current_turn = GS.PLAYER.P1
        state.round        = 1
        state.phase        = "lobby"
        state.winner       = nil
        state.ready        = { p1 = false, p2 = false }

        -- Lobby
        lobbyPhase(state, perifs.monitor)

        -- Round loop
        while state.phase ~= "game_over" do
            -- Load magazine
            loadingPhase(state, perifs)
            CD.drawHUD(perifs.monitor, GS.snapshot(state))

            -- Turn loop within this magazine
            while not GS.magazineEmpty(state) and state.phase == "playing" do
                local continueGame = runTurn(state, perifs)
                if not continueGame then break end
            end

            -- If game still going and magazine empty, reload next round
            if state.phase == "playing" then
                state.round = state.round + 1
                print("[Admin] Round " .. state.round .. " begins.")
                broadcastMessage(state, "New round! Reloading...")
                sleep(1)
            end
        end

        -- Game over
        gameOverPhase(state, perifs)
        print("[Admin] Restarting lobby...")
    end
end

-- ── Run with fault tolerance ───────────────────────────────────────────────
while true do
    local success, err = pcall(main)
    if not success then
        print("[Admin] CRASH: " .. tostring(err))
        print("[Admin] Restarting in 5 seconds...")
        sleep(5)
    end
end
