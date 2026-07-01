-- ============================================================
--  SILO BUILDER  –  cylinder + dome turtle construction script
--  Uses relative coordinates (no GPS required)
--  Turtle starts at the CENTRE of the future structure,
--  ground level, facing any direction (doesn't matter).
-- ============================================================

-- ──────────────────────────────────────────────────────────
--  RELATIVE POSITION TRACKER
-- ──────────────────────────────────────────────────────────
local pos = { x = 0, y = 0, z = 0 }   -- relative to start
local facing = 0  -- 0=north(+z), 1=east(+x), 2=south(-z), 3=west(-x)
-- ComputerCraft default: forward = -Z in world, but we just need
-- consistent internal axes, so we define:
--   facing 0 → dz = -1 (forward)
--   facing 1 → dx = +1 (right)
--   facing 2 → dz = +1 (backward)
--   facing 3 → dx = -1 (left)

local function hasDiamondPick()
    -- Check if a diamond pickaxe is equipped (slot doesn't matter for dig)
    -- We just attempt turtle.dig() when needed; the pick being equipped is
    -- signalled by the user. We expose a flag they confirmed at startup.
    return _G.hasPick
end

local function tryDig()
    if hasDiamondPick() then
        turtle.dig()
    end
end

local function tryDigUp()
    if hasDiamondPick() then
        turtle.digUp()
    end
end

local function tryDigDown()
    if hasDiamondPick() then
        turtle.digDown()
    end
end

local function forward()
    tryDig()
    local ok = turtle.forward()
    if ok then
        if     facing == 0 then pos.z = pos.z - 1
        elseif facing == 1 then pos.x = pos.x + 1
        elseif facing == 2 then pos.z = pos.z + 1
        elseif facing == 3 then pos.x = pos.x - 1
        end
    end
    return ok
end

local function back()
    local ok = turtle.back()
    if ok then
        if     facing == 0 then pos.z = pos.z + 1
        elseif facing == 1 then pos.x = pos.x - 1
        elseif facing == 2 then pos.z = pos.z - 1
        elseif facing == 3 then pos.x = pos.x + 1
        end
    end
    return ok
end

local function up()
    tryDigUp()
    local ok = turtle.up()
    if ok then pos.y = pos.y + 1 end
    return ok
end

local function down()
    tryDigDown()
    local ok = turtle.down()
    if ok then pos.y = pos.y - 1 end
    return ok
end

local function turnLeft()
    turtle.turnLeft()
    facing = (facing - 1) % 4
end

local function turnRight()
    turtle.turnRight()
    facing = (facing + 1) % 4
end

-- Turn to face a specific internal direction (0-3)
local function faceDir(dir)
    local diff = (dir - facing) % 4
    if diff == 1 then turnRight()
    elseif diff == 2 then turnRight(); turnRight()
    elseif diff == 3 then turnLeft()
    end
end

-- ──────────────────────────────────────────────────────────
--  MOVEMENT: go to an (x, y, z) relative to start
-- ──────────────────────────────────────────────────────────
local function moveTo(tx, ty, tz)
    -- Y first (up/down)
    while pos.y < ty do up() end
    while pos.y > ty do down() end

    -- X axis
    if tx > pos.x then
        faceDir(1)
        while pos.x < tx do forward() end
    elseif tx < pos.x then
        faceDir(3)
        while pos.x > tx do forward() end
    end

    -- Z axis
    if tz > pos.z then
        faceDir(2)
        while pos.z < tz do forward() end
    elseif tz < pos.z then
        faceDir(0)
        while pos.z > tz do forward() end
    end
end

-- ──────────────────────────────────────────────────────────
--  INVENTORY HELPERS
-- ──────────────────────────────────────────────────────────
-- Slot 1  = main building material
-- Slot 2  = glass / spoke-fill material (optional, 0 = none)
-- Slot 16 = diamond pickaxe (by convention; actual equipping done by user)

local function selectMaterial(useGlass)
    if useGlass then
        turtle.select(2)
    else
        turtle.select(1)
    end
end

local function placeDown(useGlass)
    selectMaterial(useGlass)
    if not turtle.placeDown() then
        -- block already there – that's fine
    end
end

local function placeUp(useGlass)
    selectMaterial(useGlass)
    turtle.placeUp()
end

-- ──────────────────────────────────────────────────────────
--  GEOMETRY HELPERS
-- ──────────────────────────────────────────────────────────

-- Returns true if (x, z) sits on the hollow ring of the given radius.
-- We use the "closest integer ring" method: a block is on the ring if
-- its rounded distance from centre is exactly r.
local function onRing(x, z, r)
    local d = math.sqrt(x * x + z * z)
    return math.floor(d + 0.5) == r
end

-- Cardinal check: is (x,z) on a cardinal axis? (one coord == 0)
local function isCardinal(x, z)
    return x == 0 or z == 0
end

-- For the dome: given a slice at height h above the cylinder top,
-- return the radius of that slice.
-- We use a quarter-ellipse:  (x/R)^2 + (y/H)^2 = 1  → x = R*sqrt(1-(y/H)^2)
local function domeSliceRadius(h, domeH, cylR)
    if h >= domeH then return 0 end
    local frac = 1 - (h / domeH) ^ 2
    if frac < 0 then frac = 0 end
    return math.floor(cylR * math.sqrt(frac) + 0.5)
end

-- ──────────────────────────────────────────────────────────
--  RING LAYER BUILDER
--  Places a hollow ring at the current turtle Y
--  (turtle navigates to each block, places below itself)
-- ──────────────────────────────────────────────────────────
local function buildRing(radius, yLevel, useGlassCheck)
    -- useGlassCheck(x,z) → true/false whether to use glass slot
    for x = -radius, radius do
        for z = -radius, radius do
            if onRing(x, z, radius) then
                local glass = false
                if useGlassCheck then
                    glass = useGlassCheck(x, z)
                end
                moveTo(x, yLevel + 1, z)  -- hover one above target
                placeDown(glass)
            end
        end
    end
end

-- ──────────────────────────────────────────────────────────
--  FILLED CIRCLE (for the very top cap of the dome)
-- ──────────────────────────────────────────────────────────
local function buildFilledCircle(radius, yLevel, useGlassCheck)
    for x = -radius, radius do
        for z = -radius, radius do
            local d = math.sqrt(x * x + z * z)
            if d <= radius + 0.5 then
                local glass = false
                if useGlassCheck then
                    glass = useGlassCheck(x, z)
                end
                moveTo(x, yLevel + 1, z)
                placeDown(glass)
            end
        end
    end
end

-- ──────────────────────────────────────────────────────────
--  PROMPT HELPERS
-- ──────────────────────────────────────────────────────────
local function prompt(msg, default)
    io.write(msg)
    local input = io.read()
    if input == nil or input == "" then return default end
    return input
end

local function promptInt(msg, default)
    local v = tonumber(prompt(msg, tostring(default)))
    return v or default
end

local function promptBool(msg)
    local v = prompt(msg .. " (y/n): ", "n")
    return v:lower():sub(1,1) == "y"
end

-- ──────────────────────────────────────────────────────────
--  MAIN
-- ──────────────────────────────────────────────────────────

print("=================================")
print("   SILO BUILDER  –  CC Turtle")
print("=================================")
print("Turtle should be at the CENTRE")
print("of the build area, ground level.")
print()

local cylRadius  = promptInt("Cylinder radius (blocks): ", 5)
local cylHeight  = promptInt("Cylinder height (blocks): ", 8)
local domeHeight = promptInt("Dome height (blocks): ", 4)

print()
print("Slot 1 = main building material (bricks, stone, etc.)")
print("Slot 2 = glass for dome spokes (optional)")
print()

local useGlass = false
local hasGlassSlot = false

if promptBool("Use glass for non-cardinal dome sections?") then
    useGlass = true
    hasGlassSlot = true
    print("Make sure your glass is in slot 2.")
end

print()
_G.hasPick = promptBool("Diamond pickaxe equipped? (will dig obstructions)")
print()
print("Starting build in 3 seconds…")
os.sleep(3)

-- ── 1. BUILD THE CYLINDER ─────────────────────────────────
print("Building cylinder…")

for layer = 0, cylHeight - 1 do
    -- yLevel = layer means blocks sit at y = layer (relative to start)
    -- turtle hovers at y = layer+1 to placeDown
    buildRing(cylRadius, layer, nil)
    print(string.format("  Cylinder layer %d/%d done", layer + 1, cylHeight))
end

-- ── 2. BUILD THE DOME ─────────────────────────────────────
print("Building dome…")

-- The dome sits on top of the cylinder.
-- Layer 0 of the dome is at y = cylHeight (world block y).
-- We iterate h = 0 .. domeHeight.

for h = 0, domeHeight do
    local sliceR = domeSliceRadius(h, domeHeight, cylRadius)
    local yLevel = cylHeight + h   -- block level in relative coords

    if sliceR == 0 then
        -- Single capstone at the very top
        moveTo(0, yLevel + 1, 0)
        placeDown(false)
        print(string.format("  Dome capstone at h=%d done", h))
    else
        local glassCheck = nil
        if useGlass and hasGlassSlot then
            -- Cardinal (N/E/S/W) = main material, diagonals = glass
            glassCheck = function(x, z)
                return not isCardinal(x, z)
            end
        end

        if h == domeHeight - 1 and sliceR <= 1 then
            buildFilledCircle(sliceR, yLevel, glassCheck)
        else
            buildRing(sliceR, yLevel, glassCheck)
        end
        print(string.format("  Dome layer %d/%d (r=%d) done", h + 1, domeHeight, sliceR))
    end
end

-- ── 3. RETURN HOME ────────────────────────────────────────
print("Returning to start position…")
moveTo(0, 0, 0)
faceDir(0)  -- face original direction

print()
print("=================================")
print("   BUILD COMPLETE!")
print(string.format("   Cylinder: r=%d  h=%d", cylRadius, cylHeight))
print(string.format("   Dome:     r=%d  h=%d", cylRadius, domeHeight))
print("=================================")
