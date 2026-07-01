-- motor_ctrl.lua  (RouletteMotorCtrl)
-- ============================================================
-- Physical mechanism controller — normal (non-advanced) computer.
-- Controls TWO gearboxes and TWO motors:
--
--   Gearbox #1 (lift)  + Motor #1  → lifts/retracts the mechanism
--   Gearbox #2 (aim)   + Motor #2  → rotates to aim, fires drill
--
-- Sequence received from Admin:
--   1. LIFT    → gearbox #1 raises mechanism toward admin computer
--   2. AIM     → gearbox #2 rotates 90° toward target player
--                (P1 = counter-clockwise, P2 = clockwise)
--   3. ATTACK  → motor #2 spins drill for 3s — LIVE shells only
--   4. RETURN  → gearbox #2 rotates back to neutral position
--   5. RETRACT → gearbox #1 lowers mechanism back down
--
-- Hardware side assignment (configurable via SIDE table below):
--   LIFT_GEARBOX  = side where gearbox #1 is attached
--   LIFT_MOTOR    = side where motor #1 is attached
--   AIM_GEARBOX   = side where gearbox #2 is attached
--   ATTACK_MOTOR  = side where motor #2 (drill) is attached
-- ============================================================

local Net = require("network")

-- ── Hardware Side Configuration ─────────────────────────────────────────────
-- Adjust these side names to match your physical layout.
-- Use a monitor or print(peripheral.getSide(handle)) to find the correct side.
local SIDE = {
    LIFT_GEARBOX  = "left",    -- Gearbox #1 (raises/lowers the mechanism)
    LIFT_MOTOR    = "back",    -- Motor #1  (powers gearbox #1)
    AIM_GEARBOX   = "right",   -- Gearbox #2 (rotates to aim at P1/P2)
    ATTACK_MOTOR  = "top",     -- Motor #2  (drill — runs 3s for live shots)
}

-- ── Timing Constants ────────────────────────────────────────────────────────
local LIFT_TIME      = 2.0   -- seconds for lift mechanism to reach admin
local ATTACK_TIME    = 3.0   -- seconds the drill spins for a live shot
local SETTLE_TIME    = 0.5   -- brief pause after any mechanical action

-- ── Motor Speed Constants ──────────────────────────────────────────────────
local NORMAL_RPM      = 64   -- Drill speed
local LIFT_RPM        = 32   -- Lift/retract speed (slower for safety)

-- ── Peripheral Discovery ───────────────────────────────────────────────────

--- Find a peripheral on a specific side, checking for matching type names.
--- Returns wrapped handle or nil.
local function findOnSide(side, typeSubstrings)
    if not side then return nil end
    local t = peripheral.getType(side)
    if not t then return nil end
    local lower = string.lower(t)
    for _, sub in ipairs(typeSubstrings) do
        if string.find(lower, sub) then
            print("[MotorCtrl] Found " .. t .. " on side " .. side)
            return peripheral.wrap(side)
        end
    end
    return nil
end

--- Fallback: find any peripheral matching type substrings via peripheral.find.
local function findAny(typeSubstrings)
    local all = { peripheral.find() }
    for _, p in ipairs(all) do
        local t = peripheral.getType(p) or ""
        local lower = string.lower(t)
        for _, sub in ipairs(typeSubstrings) do
            if string.find(lower, sub) then
                local name = peripheral.getName(p)
                print("[MotorCtrl] Found " .. t .. " (fallback, name: " .. name .. ")")
                return p
            end
        end
    end
    return nil
end

--- Discover all hardware peripherals.
--- Tries exact side mapping first, then falls back to peripheral.find().
local function discoverPeripherals()
    local p = {}

    -- Gearbox #1 — lift
    p.liftGearbox = findOnSide(SIDE.LIFT_GEARBOX,
        {"gearbox", "sequenti", "gearshift", "gear"})
    if not p.liftGearbox then
        p.liftGearbox = findAny({"gearbox", "sequenti", "gearshift", "gear"})
    end

    -- Motor #1 — lift power
    p.liftMotor = findOnSide(SIDE.LIFT_MOTOR, {"motor", "electric"})
    if not p.liftMotor then
        p.liftMotor = findAny({"motor", "electric"})
    end

    -- Gearbox #2 — aim
    p.aimGearbox = findOnSide(SIDE.AIM_GEARBOX,
        {"gearbox", "sequenti", "gearshift", "gear"})
    -- If we already found liftGearbox via findAny, aimGearbox needs
    -- to be a DIFFERENT one. We'll resolve duplicates at the end.

    -- Motor #2 — attack drill
    p.attackMotor = findOnSide(SIDE.ATTACK_MOTOR, {"motor", "electric"})

    -- Resolve duplicates: if two peripherals ended up with the same handle,
    -- scan all sides to fill in the missing one
    p = resolveDuplicates(p)

    -- Report
    print("[MotorCtrl] Lift gearbox:  " .. tostring(p.liftGearbox and "FOUND" or "MISSING"))
    print("[MotorCtrl] Lift motor:    " .. tostring(p.liftMotor and "FOUND" or "MISSING"))
    print("[MotorCtrl] Aim gearbox:   " .. tostring(p.aimGearbox and "FOUND" or "MISSING"))
    print("[MotorCtrl] Attack motor:  " .. tostring(p.attackMotor and "FOUND" or "MISSING"))

    return p
end

--- If any two peripherals references are the same handle, do a full side scan
--- to find the distinct peripherals by side position.
local function resolveDuplicates(perifs)
    local handles = {}
    local function add(key, h)
        if h then handles[key] = h end
    end
    add("liftGearbox", perifs.liftGearbox)
    add("liftMotor", perifs.liftMotor)
    add("aimGearbox", perifs.aimGearbox)
    add("attackMotor", perifs.attackMotor)

    -- Check for duplicates by comparing peripheral names
    local nameMap = {}  -- peripheral name -> key
    for key, h in pairs(handles) do
        local n = peripheral.getName(h)
        if nameMap[n] then
            -- Duplicate! This peripheral was found for two roles.
            -- Try a full side scan to find the right one for this key.
            print("[MotorCtrl] Duplicate " .. n .. " for " .. key .. " and "
                  .. nameMap[n] .. ". Re-scanning sides...")
            local found = scanAllSidesForKey(key)
            if found then
                perifs[key] = found
                handles[key] = found
                nameMap[peripheral.getName(found)] = key
            end
        else
            nameMap[n] = key
        end
    end

    return perifs
end

--- Scan all six sides for a peripheral matching this role's type pattern.
local function scanAllSidesForKey(key)
    local patterns = {
        liftGearbox = {"gearbox", "sequenti", "gearshift", "gear"},
        liftMotor   = {"motor", "electric"},
        aimGearbox  = {"gearbox", "sequenti", "gearshift", "gear"},
        attackMotor = {"motor", "electric"},
    }
    local subs = patterns[key]
    if not subs then return nil end

    for _, side in ipairs({"top", "bottom", "left", "right", "front", "back"}) do
        local t = peripheral.getType(side)
        if t then
            local lower = string.lower(t)
            for _, sub in ipairs(subs) do
                if string.find(lower, sub) then
                    print("[MotorCtrl] Side-scan: found on " .. side)
                    return peripheral.wrap(side)
                end
            end
        end
    end
    return nil
end

-- ── Hardware Control ───────────────────────────────────────────────────────

--- Set a motor's RPM. No-ops if motor is nil.
---@param motor table|nil
---@param rpm   number
local function setMotorRPM(motor, rpm)
    if not motor then
        print("[MotorCtrl] (No motor) Would set RPM to " .. rpm)
        return
    end
    local ok, err = pcall(function()
        motor.setSpeed(rpm)
    end)
    if not ok then
        print("[MotorCtrl] setSpeed failed: " .. tostring(err))
    end
end

--- Stop a motor.
---@param motor table|nil
local function stopMotor(motor)
    if not motor then return end
    pcall(function() motor.setSpeed(0) end)
end

--- Rotate a gearbox with multi-API fallback.
---@param gearbox table|nil
---@param steps   number
---@param dir     number  +1 or -1
local function rotateGearbox(gearbox, steps, dir)
    if not gearbox then
        print("[MotorCtrl] (No gearbox) Would rotate " .. steps .. " steps dir=" .. dir)
        return
    end

    local ok = false
    -- Pattern A: rotate(steps, direction)
    ok = pcall(function() gearbox.rotate(steps, dir) end)
    if ok then return end
    -- Pattern B: stepForward / stepBackward
    if dir > 0 then
        ok = pcall(function() gearbox.stepForward(steps) end)
    else
        ok = pcall(function() gearbox.stepBackward(steps) end)
    end
    if ok then return end
    -- Pattern C: setAngle
    ok = pcall(function() gearbox.setAngle(dir > 0 and 90 or -90) end)
    if ok then return end

    print("[MotorCtrl] WARNING: Could not rotate gearbox. Check peripheral API.")
end

--- Return a gearbox to its neutral/home angle.
--- Assumes neutral is 0 degrees (the opposite of the current aim rotation).
---@param gearbox table|nil
local function returnGearbox(gearbox)
    if not gearbox then return end
    -- Try setAngle(0) for absolute positioning gearboxes
    local ok = pcall(function() gearbox.setAngle(0) end)
    if ok then return end
    -- Fallback: rotate the same amount in the opposite direction (handled by caller)
    print("[MotorCtrl] WARNING: Could not return gearbox to neutral via setAngle.")
end

-- ── Command Handlers ───────────────────────────────────────────────────────

--- LIFT: Raise the mechanism by running motor #1 + gearbox #1.
---@param perifs    table
---@param senderId  number
local function handleLift(perifs, senderId)
    print("[MotorCtrl] LIFT: Raising mechanism...")

    -- Start motor #1 to drive gearbox #1
    setMotorRPM(perifs.liftMotor, LIFT_RPM)

    -- Run the lift for the configured duration
    -- The admin computer will detect when the mechanism reaches it
    -- (via peripheral detection on its bottom side) and proceed.
    -- We just run the motor and wait for the admin's next command.
    sleep(LIFT_TIME)

    -- Stop lift motor
    stopMotor(perifs.liftMotor)
    sleep(SETTLE_TIME)

    print("[MotorCtrl] LIFT complete.")
    -- Acknowledge — the admin is responsible for detecting arrival
    Net.send(senderId, Net.PKT.LIFT_DONE, {})
end

--- AIM: Rotate gearbox #2 to face the target player.
---@param perifs    table
---@param target    string  "p1" or "p2"
---@param senderId  number
local function handleAim(perifs, target, senderId)
    local dir = (target == "p1") and -1 or 1
    local label = (target == "p1") and "Player 1 (CCW)" or "Player 2 (CW)"
    print("[MotorCtrl] AIM: Rotating toward " .. label)

    rotateGearbox(perifs.aimGearbox, 90, dir)
    sleep(SETTLE_TIME)

    print("[MotorCtrl] AIM complete.")
    Net.send(senderId, Net.PKT.AIM_DONE, { target = target })
end

--- ATTACK: Run motor #2 (drill) for 3 seconds.
---@param perifs    table
---@param senderId  number
local function handleAttack(perifs, senderId)
    print("[MotorCtrl] ATTACK: Spinning drill...")

    setMotorRPM(perifs.attackMotor, NORMAL_RPM)
    sleep(ATTACK_TIME)
    stopMotor(perifs.attackMotor)
    sleep(SETTLE_TIME)

    print("[MotorCtrl] ATTACK complete.")
    Net.send(senderId, Net.PKT.ATTACK_DONE, {})
end

--- RETURN: Rotate gearbox #2 back to neutral position.
---@param perifs    table
---@param senderId  number
local function handleReturn(perifs, senderId)
    print("[MotorCtrl] RETURN: Returning gearbox to neutral...")

    returnGearbox(perifs.aimGearbox)
    sleep(SETTLE_TIME)

    print("[MotorCtrl] RETURN complete.")
    Net.send(senderId, Net.PKT.RETURN_DONE, {})
end

--- RETRACT: Lower the mechanism via gearbox #1 (reverse).
---@param perifs    table
---@param senderId  number
local function handleRetract(perifs, senderId)
    print("[MotorCtrl] RETRACT: Lowering mechanism...")

    -- Run lift motor in reverse (negative RPM or rotate opposite direction)
    -- First try rotating gearbox #1 in reverse
    rotateGearbox(perifs.liftGearbox, 90, -1)
    sleep(LIFT_TIME + SETTLE_TIME)

    print("[MotorCtrl] RETRACT complete.")
    Net.send(senderId, Net.PKT.RETRACT_DONE, {})
end

-- ── Main Entry Point ───────────────────────────────────────────────────────

local HOST_ADMIN = "RouletteAdmin"

local function main()
    -- 1. Open modem
    local ok, err = Net.open()
    if not ok then
        error("[MotorCtrl] Fatal: " .. (err or "Cannot open modem."))
    end
    print("[MotorCtrl] Label: " .. Net.hostname())

    -- 2. Discover peripherals
    local perifs = discoverPeripherals()

    -- 3. Discover admin
    print("[MotorCtrl] Waiting for RouletteAdmin to find us...")
    local adminId
    parallel.waitForAny(
        function()
            adminId = Net.discover(HOST_ADMIN)
        end,
        function()
            Net.answerDiscovery()
        end
    )
    print("[MotorCtrl] Admin found at ID " .. tostring(adminId))

    -- 4. Command loop
    print("[MotorCtrl] Ready. Awaiting commands.")

    while true do
        local pkt, senderId = Net.receive(nil, 30)

        if pkt and senderId then
            local t = pkt.type

            if t == Net.PKT.LIFT then
                handleLift(perifs, senderId)

            elseif t == Net.PKT.AIM then
                local target = pkt.payload.target or "p1"
                handleAim(perifs, target, senderId)

            elseif t == Net.PKT.ATTACK then
                handleAttack(perifs, senderId)

            elseif t == Net.PKT.RETURN then
                handleReturn(perifs, senderId)

            elseif t == Net.PKT.RETRACT then
                handleRetract(perifs, senderId)

            elseif t == Net.PKT.PING then
                Net.send(senderId, Net.PKT.PONG, {})

            else
                print("[MotorCtrl] Unknown/obsolete packet type: " .. tostring(t))
            end
        end
    end
end

-- ── Run with fault tolerance ───────────────────────────────────────────────
while true do
    local success, err = pcall(main)
    if not success then
        print("[MotorCtrl] CRASH: " .. tostring(err))
        print("[MotorCtrl] Restarting in 5 seconds...")
        sleep(5)
    end
end
