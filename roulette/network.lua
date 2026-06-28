-- lib/network.lua
-- Rednet communication helpers, packet types, and hostname discovery.
-- All computers share this module.
--
-- Packet structure (serialized table):
--   { type = PKT.*, sender = "hostname", recipient = "hostname"|"*", payload = {...} }
--
-- Usage:
--   local Net = require("lib.network")
--   Net.open()                          -- open the wired modem
--   Net.discover("RouletteAdmin")       -- block until host is found, return id
--   Net.send("RouletteAdmin", PKT.READY, {player = "Roulette1"})
--   local pkt = Net.receive(PKT.READY, 5)  -- timeout 5 s, nil on timeout

local Net = {}

-- ── Packet type constants ──────────────────────────────────────────────────
Net.PKT = {
    -- Discovery
    WHO_ARE_YOU   = "WHO_ARE_YOU",
    I_AM          = "I_AM",

    -- Lobby
    READY         = "READY",
    START_GAME    = "START_GAME",

    -- Turn lifecycle
    YOUR_TURN     = "YOUR_TURN",
    PLAYER_ACTION = "PLAYER_ACTION",   -- payload: { action = "self"|"opponent" }
    TURN_RESULT   = "TURN_RESULT",     -- payload: { shell, damage, next_turn, health }
    WAITING       = "WAITING",

    -- Motor control
    AIM           = "AIM",            -- payload: { target = "p1"|"p2" }
    FIRE          = "FIRE",           -- payload: { rpm = number }
    MOTOR_DONE    = "MOTOR_DONE",

    -- Inventory / magazine
    LOAD_MAGAZINE = "LOAD_MAGAZINE",  -- payload: { shells = [...] }
    ITEM_MOVED    = "ITEM_MOVED",

    -- Display / status
    HEALTH_UPDATE = "HEALTH_UPDATE",  -- payload: { p1 = n, p2 = n }
    SHOW_MESSAGE  = "SHOW_MESSAGE",   -- payload: { text = "..." }
    GAME_OVER     = "GAME_OVER",      -- payload: { winner = "p1"|"p2" }

    -- Fault
    ERROR         = "ERROR",          -- payload: { message = "..." }
    PING          = "PING",
    PONG          = "PONG",
}

-- ── Internal state ─────────────────────────────────────────────────────────
local _modem      = nil   -- peripheral handle
local _modemSide  = nil   -- side string (for rednet.open)
local _hostname   = nil   -- this computer's label

-- ── Helpers ───────────────────────────────────────────────────────────────

--- Find and open the first wired modem attached to this computer.
--- Returns true on success, false + reason string on failure.
function Net.open()
    -- Locate the modem
    for _, side in ipairs({"top","bottom","left","right","front","back"}) do
        if peripheral.getType(side) == "modem" then
            local m = peripheral.wrap(side)
            if m and m.isWireless and not m.isWireless() then
                _modem     = m
                _modemSide = side
                rednet.open(side)
                _hostname = os.getComputerLabel() or ("computer_" .. os.getComputerID())
                return true
            end
        end
    end
    -- Also try peripheral.find for networked (multi-block) cable modems
    local found = { peripheral.find("modem") }
    for _, m in ipairs(found) do
        if not m.isWireless() then
            -- derive side from peripheral name
            local name = peripheral.getName(m)
            _modem     = m
            _modemSide = name
            rednet.open(name)
            _hostname = os.getComputerLabel() or ("computer_" .. os.getComputerID())
            return true
        end
    end
    return false, "No wired modem found."
end

--- Return this computer's label (hostname).
function Net.hostname()
    return _hostname
end

--- Broadcast a discovery beacon and listen for responses.
--- Blocks until `targetLabel` replies, then returns its numeric Rednet ID.
--- Retries indefinitely with `retryDelay` seconds between attempts.
---@param targetLabel string
---@param retryDelay  number   (default 3)
---@return number id
function Net.discover(targetLabel, retryDelay)
    retryDelay = retryDelay or 3
    print("[Net] Discovering " .. targetLabel .. "...")

    -- Register ourselves so others can find us by label
    rednet.host("roulette", _hostname)

    while true do
        -- Try a direct lookup first (O(1) if already hosted)
        local id = rednet.lookup("roulette", targetLabel)
        if id then
            print("[Net] Found " .. targetLabel .. " at ID " .. id)
            return id
        end

        -- Broadcast WHO_ARE_YOU and wait for a reply
        rednet.broadcast(textutils.serialise({
            type      = Net.PKT.WHO_ARE_YOU,
            sender    = _hostname,
            recipient = "*",
            payload   = {},
        }), "roulette_discovery")

        -- Listen briefly for I_AM replies
        local deadline = os.clock() + retryDelay
        while os.clock() < deadline do
            local senderId, raw = rednet.receive("roulette_discovery", 0.5)
            if senderId and raw then
                local ok, pkt = pcall(textutils.unserialise, raw)
                if ok and pkt and pkt.type == Net.PKT.I_AM and pkt.sender == targetLabel then
                    print("[Net] Found " .. targetLabel .. " at ID " .. senderId)
                    return senderId
                end
            end
        end

        print("[Net] " .. targetLabel .. " not found, retrying in " .. retryDelay .. "s...")
        sleep(retryDelay)
    end
end

--- Reply to WHO_ARE_YOU discovery broadcasts.
--- Call this in a coroutine or parallel task during startup.
function Net.answerDiscovery()
    rednet.host("roulette", _hostname)
    while true do
        local senderId, raw = rednet.receive("roulette_discovery", 1)
        if senderId and raw then
            local ok, pkt = pcall(textutils.unserialise, raw)
            if ok and pkt and pkt.type == Net.PKT.WHO_ARE_YOU then
                rednet.send(senderId, textutils.serialise({
                    type      = Net.PKT.I_AM,
                    sender    = _hostname,
                    recipient = pkt.sender,
                    payload   = {},
                }), "roulette_discovery")
            end
        end
    end
end

--- Send a typed packet to a specific Rednet ID.
---@param recipientId number
---@param packetType  string  Net.PKT.*
---@param payload     table
function Net.send(recipientId, packetType, payload)
    local pkt = {
        type      = packetType,
        sender    = _hostname,
        recipient = recipientId,
        payload   = payload or {},
    }
    rednet.send(recipientId, textutils.serialise(pkt), "roulette")
end

--- Broadcast a typed packet to all computers.
---@param packetType string  Net.PKT.*
---@param payload    table
function Net.broadcast(packetType, payload)
    local pkt = {
        type      = packetType,
        sender    = _hostname,
        recipient = "*",
        payload   = payload or {},
    }
    rednet.broadcast(textutils.serialise(pkt), "roulette")
end

--- Receive the next packet on the "roulette" channel.
--- Optionally filter by packet type.
--- Returns (packet, senderId) or (nil, nil) on timeout.
---@param filterType string|nil
---@param timeout    number|nil
---@return table|nil, number|nil
function Net.receive(filterType, timeout)
    local deadline = timeout and (os.clock() + timeout) or nil

    while true do
        local remaining = deadline and (deadline - os.clock()) or nil
        if deadline and remaining <= 0 then
            return nil, nil
        end

        local senderId, raw = rednet.receive("roulette", remaining or 10)
        if senderId and raw then
            local ok, pkt = pcall(textutils.unserialise, raw)
            if ok and pkt then
                if not filterType or pkt.type == filterType then
                    return pkt, senderId
                end
                -- Wrong type — keep waiting (time still counts)
            end
        elseif deadline then
            return nil, nil
        end
    end
end

--- Ping a remote computer; return round-trip ms or nil on timeout.
---@param recipientId number
---@param timeout     number  (default 3)
---@return number|nil
function Net.ping(recipientId, timeout)
    timeout = timeout or 3
    local t0 = os.clock()
    Net.send(recipientId, Net.PKT.PING, {})
    local pkt = Net.receive(Net.PKT.PONG, timeout)
    if pkt then
        return math.floor((os.clock() - t0) * 1000)
    end
    return nil
end

--- Respond to PING packets — call this in a background coroutine.
function Net.handlePings(adminId)
    while true do
        local pkt, sid = Net.receive(Net.PKT.PING, 5)
        if pkt and sid then
            Net.send(sid, Net.PKT.PONG, {})
        end
    end
end

return Net
