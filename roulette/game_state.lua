-- lib/game_state.lua
-- Authoritative game-state definitions used by RouletteAdmin.
-- Players receive copies via network packets; they never hold the source of truth.
--
-- Shell types map to physical Create/Mekanism items via SHELL_ITEMS below.

local GameState = {}

-- ── Shell Definitions ──────────────────────────────────────────────────────

--- Shell type identifiers (internal keys).
GameState.SHELL = {
    LIVE  = "LIVE",   -- Infused Alloy     — deals damage
    BLANK = "BLANK",  -- Reinforced Alloy  — no damage; grants extra turn if self-shot
}

--- Maps shell type → Minecraft item ID (for inventory automation).
--- Edit these to match your exact item IDs in your modpack.
GameState.SHELL_ITEMS = {
    [GameState.SHELL.LIVE]  = "mekanism:infused_alloy",
    [GameState.SHELL.BLANK] = "mekanism:reinforced_alloy",
}

--- Human-readable shell names for the center display.
GameState.SHELL_NAMES = {
    [GameState.SHELL.LIVE]  = "Live Round",
    [GameState.SHELL.BLANK] = "Blank Round",
}

-- ── Game Constants ─────────────────────────────────────────────────────────

GameState.MAX_HEALTH     = 3   -- Hearts per player
GameState.MAX_MAG_SIZE   = 8   -- Maximum shells per magazine
GameState.MIN_LIVE       = 1   -- Minimum live shells per magazine
GameState.MIN_BLANK      = 1   -- Minimum blank shells per magazine

-- Player identifiers (used in packets and state tables)
GameState.PLAYER = {
    P1 = "p1",
    P2 = "p2",
}

-- ── State Constructor ──────────────────────────────────────────────────────

--- Create a fresh game state table.
--- RouletteAdmin holds one of these for the entire game session.
---@return table
function GameState.new()
    return {
        -- Player health (current hearts)
        health = {
            p1 = GameState.MAX_HEALTH,
            p2 = GameState.MAX_HEALTH,
        },

        -- Whose turn it is ("p1" or "p2")
        current_turn = GameState.PLAYER.P1,

        -- Round counter (increments each time the magazine is reloaded)
        round = 1,

        -- Magazine: ordered list of shell type strings (front = next to fire)
        -- e.g. { "LIVE", "BLANK", "BLANK", "LIVE" }
        magazine = {},

        -- Total shells generated this round (for display)
        round_live  = 0,
        round_blank = 0,

        -- Game phase: "lobby" | "loading" | "playing" | "game_over"
        phase = "lobby",

        -- Winner ("p1", "p2", or nil)
        winner = nil,

        -- Ready flags
        ready = { p1 = false, p2 = false },

        -- Rednet IDs of connected clients (filled during discovery)
        ids = {
            p1        = nil,
            p2        = nil,
            motorCtrl = nil,
        },
    }
end

-- ── Magazine Generation ────────────────────────────────────────────────────

--- Generate a randomized magazine.
--- Returns ordered list of shell type strings and counts.
---@param size number  (optional, default random 2–MAX_MAG_SIZE)
---@return table shells, number liveCount, number blankCount
function GameState.generateMagazine(size)
    size = size or math.random(2, GameState.MAX_MAG_SIZE)

    -- Ensure at least one of each type
    local liveCount  = math.random(GameState.MIN_LIVE,  size - GameState.MIN_BLANK)
    local blankCount = size - liveCount

    -- Build and shuffle the list
    local shells = {}
    for _ = 1, liveCount  do table.insert(shells, GameState.SHELL.LIVE)  end
    for _ = 1, blankCount do table.insert(shells, GameState.SHELL.BLANK) end

    -- Fisher-Yates shuffle
    for i = #shells, 2, -1 do
        local j = math.random(1, i)
        shells[i], shells[j] = shells[j], shells[i]
    end

    return shells, liveCount, blankCount
end

-- ── Turn Logic ─────────────────────────────────────────────────────────────

--- Pop the next shell from the magazine (mutates state.magazine).
--- Returns the shell type string, or nil if empty.
---@param state table
---@return string|nil
function GameState.popShell(state)
    if #state.magazine == 0 then return nil end
    return table.remove(state.magazine, 1)
end

--- Apply the result of a fired shell to game state.
--- Returns a result table describing what happened.
---
--- action:  "self" | "opponent"
--- shell:   GameState.SHELL.*
---
---@param state  table
---@param action string
---@param shell  string
---@return table result  { damage, killed, extra_turn, next_turn }
function GameState.applyShot(state, action, shell)
    local actor  = state.current_turn                          -- who fired
    local target = (action == "self")
                   and actor
                   or (actor == GameState.PLAYER.P1 and GameState.PLAYER.P2
                                                     or GameState.PLAYER.P1)

    local result = {
        actor      = actor,
        target     = target,
        shell      = shell,
        damage     = 0,
        killed     = false,
        extra_turn = false,
        next_turn  = nil,   -- filled below
    }

    if shell == GameState.SHELL.LIVE then
        result.damage = 1
        state.health[target] = state.health[target] - 1
        if state.health[target] <= 0 then
            state.health[target] = 0
            result.killed        = true
            state.phase          = "game_over"
            state.winner         = actor
        end
        -- After a live shot, turn passes (even if self)
        result.next_turn = (actor == GameState.PLAYER.P1)
                           and GameState.PLAYER.P2
                           or  GameState.PLAYER.P1

    elseif shell == GameState.SHELL.BLANK then
        result.damage = 0
        if action == "self" then
            -- Blank self-shot: bonus turn
            result.extra_turn = true
            result.next_turn  = actor
        else
            -- Blank at opponent: turn passes
            result.next_turn = (actor == GameState.PLAYER.P1)
                               and GameState.PLAYER.P2
                               or  GameState.PLAYER.P1
        end
    end

    if state.phase ~= "game_over" then
        state.current_turn = result.next_turn
    end

    return result
end

--- Check if the magazine is empty.
---@param state table
---@return boolean
function GameState.magazineEmpty(state)
    return #state.magazine == 0
end

-- ── Serialization ──────────────────────────────────────────────────────────

--- Produce a safe snapshot of game state for transmission.
--- Omits raw peripheral handles and Rednet IDs.
---@param state table
---@return table
function GameState.snapshot(state)
    return {
        health       = { p1 = state.health.p1, p2 = state.health.p2 },
        current_turn = state.current_turn,
        round        = state.round,
        phase        = state.phase,
        winner       = state.winner,
        mag_size     = #state.magazine,
        round_live   = state.round_live,
        round_blank  = state.round_blank,
    }
end

return GameState
