-- motor_ctrl.lua  (RouletteMotorCtrl)
-- ============================================================
-- Physical drill controller — normal (non-advanced) computer.
-- Controls:
--   • Create Electric Motor   → rotation speed
--   • Sequential Gearbox      → aim direction (P1 or P2)
--
-- This computer contains NO game logic.
-- It receives structured commands from RouletteAdmin over Rednet
-- and operates hardware accordingly.
--
-- Sequential Gearbox targeting:
--   Player 1  →  rotate(90, -1)   (left)
--   Player 2  →  rotate(90,  1)   (right)
-- ============================================================

local Net = require("network")

-- ── Motor Speed Constants ──────────────────────────────────────────────────
local NORMAL_RPM       = 64    -- Standard drill speed for all shots
local DOUBLE_DAMAGE_RPM = 128  -- Future: double-damage shell type

-- ── Peripheral Discovery ───────────────────────────────────────────────────

--- Find a Create Electric Motor attached to this computer.
--- Returns the peripheral handle or nil.
local function findMotor()
    -- Try peripheral.find with all known CCA type names
    -- CCA (mrh0): "electric_motor"
    -- CCA (tom5454, older): "Create_Motor"
    for _, ptype in ipairs({"electric_motor", "Create_Motor"}) do
        local m = peripheral.find(ptype)
        if m then
            print("[MotorCtrl] Found Electric Motor (type: " .. ptype .. ").")
            return m
        end
    end
    -- Scan sides for anything with "motor" in its type
    for _, side in ipairs({"top","bottom","left","right","front","back"}) do
        local t = peripheral.getType(side)
        if t and string.find(string.lower(t), "motor") then
            print("[MotorCtrl] Found motor on side: " .. side)
            return peripheral.wrap(side)
        end
    end
    print("[MotorCtrl] WARNING: No Electric Motor found.")
    return nil
end

--- Find a Create Sequential Gearbox attached to this computer.
--- Returns the peripheral handle or nil.
local function findGearbox()
    -- Try known type names from CCA and base Create
    -- CCA (older by tom5454): "Create_SequentialGearbox"
    -- CCA (newer by mrh0):    no gearbox block; use Digital Adapter instead
    -- Base Create:             "sequenced_gearshift"
    for _, ptype in ipairs({"Create_SequentialGearbox", "sequenced_gearshift"}) do
        local g = peripheral.find(ptype)
        if g then
            print("[MotorCtrl] Found gearbox/gearshift (type: " .. ptype .. ").")
            return g
        end
    end
    -- Scan sides for anything gearbox- or gearshift-like
    for _, side in ipairs({"top","bottom","left","right","front","back"}) do
        local t = peripheral.getType(side)
        if t and (string.find(string.lower(t), "gearbox") or
                  string.find(string.lower(t), "gear") or
                  string.find(string.lower(t), "sequential") or
                  string.find(string.lower(t), "gearshift")) then
            print("[MotorCtrl] Found gearbox on side: " .. side .. " (type: " .. t .. ")")
            return peripheral.wrap(side)
        end
    end
    print("[MotorCtrl] WARNING: No gearbox/gearshift found.")
    return nil
end

--- Validate that required peripherals are present.
--- Returns table with motor and gearbox handles (may be nil individually).
local function discoverPeripherals()
    return {
        motor   = findMotor(),
        gearbox = findGearbox(),
    }
end

-- ── Hardware Control ───────────────────────────────────────────────────────

--- Set the motor's RPM.
--- Safely no-ops if motor is nil.
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

--- Stop the motor.
---@param motor table|nil
local function stopMotor(motor)
    if not motor then return end
    pcall(function() motor.setSpeed(0) end)
end

--- Rotate the Sequential Gearbox to aim at a target.
--- steps: number of gearbox "clicks" to rotate
--- dir:   +1 (clockwise / Player 2) or -1 (counter-clockwise / Player 1)
---
--- The gearbox peripheral exposes rotate(steps, direction) in some Create
--- versions; in others it uses setAngle or stepForward/stepBackward.
--- We try multiple known API patterns for compatibility.
---@param gearbox table|nil
---@param steps   number
---@param dir     number  +1 or -1
local function rotateGearbox(gearbox, steps, dir)
    if not gearbox then
        print("[MotorCtrl] (No gearbox) Would rotate " .. steps .. " steps dir=" .. dir)
        return
    end

    -- Try CC:Tweaked Create integration patterns in order of likelihood
    local ok = false

    -- Pattern A: rotate(steps, direction)
    ok = pcall(function()
        gearbox.rotate(steps, dir)
    end)
    if ok then return end

    -- Pattern B: separate forward/backward methods
    if dir > 0 then
        ok = pcall(function() gearbox.stepForward(steps) end)
    else
        ok = pcall(function() gearbox.stepBackward(steps) end)
    end
    if ok then return end

    -- Pattern C: setAngle (if gearbox exposes absolute positioning)
    ok = pcall(function()
        gearbox.setAngle(dir > 0 and 90 or -90)
    end)
    if ok then return end

    print("[MotorCtrl] WARNING: Could not rotate gearbox. Check peripheral API.")
end

-- ── Aim Logic ──────────────────────────────────────────────────────────────

--- Aim the drill at a player.
--- target: "p1" → rotate -1 (left)
---         "p2" → rotate +1 (right)
---@param perifs table
---@param target string
local function aimAt(perifs, target)
    local dir
    if target == "p1" then
        dir = -1
        print("[MotorCtrl] Aiming at Player 1 (left).")
    else
        dir = 1
        print("[MotorCtrl] Aiming at Player 2 (right).")
    end
    rotateGearbox(perifs.gearbox, 90, dir)
    sleep(0.5)  -- brief settle time after rotation
end

--- Run the drill for a shot sequence.
--- rpm = 0 means "use NORMAL_RPM"
---@param perifs table
---@param rpm    number
local function fireDrill(perifs, rpm)
    local speed = (rpm and rpm > 0) and rpm or NORMAL_RPM

    print("[MotorCtrl] Firing drill at " .. speed .. " RPM.")

    setMotorRPM(perifs.motor, speed)
    sleep(1.5)    -- drill spins, animation time
    stopMotor(perifs.motor)

    print("[MotorCtrl] Drill stopped.")
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

    -- 3. Discover admin — answer discovery beacons while searching
    print("[MotorCtrl] Waiting for RouletteAdmin to find us...")

    -- Register ourselves so admin can find us by label
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
        -- Receive any packet (AIM, FIRE, PING)
        local pkt, senderId = Net.receive(nil, 30)

        if pkt and senderId then
            local t = pkt.type

            if t == Net.PKT.AIM then
                local target = pkt.payload.target or "p1"
                aimAt(perifs, target)
                -- Acknowledge
                Net.send(senderId, Net.PKT.MOTOR_DONE, { action = "AIM", target = target })

            elseif t == Net.PKT.FIRE then
                local rpm = pkt.payload.rpm or 0
                fireDrill(perifs, rpm)
                -- Acknowledge
                Net.send(senderId, Net.PKT.MOTOR_DONE, { action = "FIRE" })

            elseif t == Net.PKT.PING then
                Net.send(senderId, Net.PKT.PONG, {})

            else
                -- Unknown command — log and ignore
                print("[MotorCtrl] Unknown packet type: " .. tostring(t))
            end
        end
        -- If receive timed out, loop and keep waiting
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
