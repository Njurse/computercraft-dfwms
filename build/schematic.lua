-- gps_printer.lua
-- Reads gps_sat.json and places blocks at the listed coordinates.
-- Supports block substitution and breaking.

local function readFile(path)
    local f = fs.open(path, "r")
    if not f then error("Could not open " .. path) end
    local content = f.readAll()
    f.close()
    return content
end

local function loadJson(path)
    local raw = readFile(path)
    local ok, data = pcall(textutils.unserializeJSON, raw)
    if not ok then error("Invalid JSON: " .. tostring(data)) end
    return data
end

local function findBlockInInventory(blockName)
    for i = 1, 16 do
        local item = turtle.getItemDetail(i)
        if item and item.name == blockName then
            return i
        end
    end
    return nil
end

local function findDiamondPickaxe()
    for i = 1, 16 do
        local item = turtle.getItemDetail(i)
        if item and string.find(item.name, "diamond_pickaxe") then
            return i
        end
    end
    return nil
end

-- Parse the JSON data into a list of targets: {x, y, z, blockType}
local function parseTargets(data)
    local targets = {}
    for _, entry in ipairs(data) do
        -- entry is like { {x,y,z}, "minecraft:white_concrete" }
        local coords = entry[1]
        local block = entry[2]
        table.insert(targets, { x = coords[1], y = coords[2], z = coords[3], block = block })
    end
    return targets
end

-- Build a map of unique block types
local function getUniqueBlocks(targets)
    local blocks = {}
    for _, t in ipairs(targets) do
        blocks[t.block] = true
    end
    local unique = {}
    for k, _ in pairs(blocks) do
        table.insert(unique, k)
    end
    return unique
end

-- Ask user for substitution mapping
local function buildSlotMap(uniqueBlocks, substitute)
    local map = {}
    if substitute then
        print("Substitution mode: for each block type, enter the slot number to use.")
        for _, blockType in ipairs(uniqueBlocks) do
            io.write("Slot for '" .. blockType .. "' (1-16): ")
            local slot = tonumber(read())
            while not slot or slot < 1 or slot > 16 do
                io.write("Invalid. Enter slot (1-16): ")
                slot = tonumber(read())
            end
            map[blockType] = slot
        end
    else
        print("Auto‑detect mode: scanning inventory for each block type.")
        for _, blockType in ipairs(uniqueBlocks) do
            local slot = findBlockInInventory(blockType)
            if slot then
                print("Found '" .. blockType .. "' in slot " .. slot)
                map[blockType] = slot
            else
                print("Could not find '" .. blockType .. "' in inventory.")
                io.write("Enter slot number for it (1-16): ")
                local s = tonumber(read())
                while not s or s < 1 or s > 16 do
                    io.write("Invalid. Enter slot (1-16): ")
                    s = tonumber(read())
                end
                map[blockType] = s
            end
        end
    end
    return map
end

-- Navigation state
local currentX, currentY, currentZ = 0, 0, 0
local facing = 1 -- 0=north,1=east,2=south,3=west (we'll use relative)

local function turnTo(desired)
    while facing ~= desired do
        turtle.turnRight()
        facing = (facing + 1) % 4
    end
end

local function moveForward(steps)
    for i = 1, math.abs(steps) do
        if steps > 0 then
            while not turtle.forward() do
                print("Blocked forward, trying to break?")
                if turtle.detect() and breakBlocks then
                    turtle.dig()
                else
                    sleep(0.5)
                end
            end
            if steps > 0 then currentX = currentX + (facing == 1 and 1 or facing == 3 and -1 or 0)
                currentZ = currentZ + (facing == 0 and -1 or facing == 2 and 1 or 0) end
        else
            while not turtle.back() do
                if turtle.detect() and breakBlocks then
                    turtle.dig()
                else
                    sleep(0.5)
                end
            end
            if steps < 0 then currentX = currentX - (facing == 1 and 1 or facing == 3 and -1 or 0)
                currentZ = currentZ - (facing == 0 and -1 or facing == 2 and 1 or 0) end
        end
    end
end

local function moveUp(steps)
    for i = 1, math.abs(steps) do
        if steps > 0 then
            while not turtle.up() do
                if turtle.detectUp() and breakBlocks then
                    turtle.digUp()
                else
                    sleep(0.5)
                end
            end
            currentY = currentY + 1
        else
            while not turtle.down() do
                if turtle.detectDown() and breakBlocks then
                    turtle.digDown()
                else
                    sleep(0.5)
                end
            end
            currentY = currentY - 1
        end
    end
end

-- Move to absolute coordinates (the position where we want to stand)
local function moveTo(targetX, targetY, targetZ)
    local dx = targetX - currentX
    local dz = targetZ - currentZ
    local dy = targetY - currentY

    -- Move horizontally: first X then Z
    if dx ~= 0 then
        if dx > 0 then
            turnTo(1) -- east
        else
            turnTo(3) -- west
        end
        moveForward(dx)
    end
    if dz ~= 0 then
        if dz > 0 then
            turnTo(2) -- south (assuming z positive is south)
        else
            turnTo(0) -- north
        end
        moveForward(dz)
    end

    -- Move vertically
    if dy ~= 0 then
        moveUp(dy)
    end
end

-- Place the block at the target coordinate (we stand one block above it)
local function placeAtTarget(target, slotMap, breakMode)
    local blockType = target.block
    local slot = slotMap[blockType]
    if not slot then
        print("No slot defined for " .. blockType .. " – skipping.")
        return false
    end

    -- Move to the position one block above the target (so we can place down)
    local standX, standY, standZ = target.x, target.y + 1, target.z
    moveTo(standX, standY, standZ)

    -- Select the block
    turtle.select(slot)
    if turtle.getItemCount(slot) == 0 then
        print("Out of blocks for " .. blockType)
        return false
    end

    -- Check below
    local success, info = turtle.inspectDown()
    if success then
        if info.name == blockType then
            print("Already correct block at ("..target.x..","..target.y..","..target.z..")")
            return true
        else
            if breakMode then
                print("Breaking " .. info.name .. " below")
                turtle.digDown()
            else
                print("Block below is " .. info.name .. " – skipping (preserve mode)")
                return false
            end
        end
    end

    -- Place
    turtle.placeDown()
    return true
end

-- Main
term.clear()
term.setCursorPos(1,1)
print("=== GPS Printer ===")

-- Load JSON
local data = loadJson("gps_sat.json")
local targets = parseTargets(data)
print("Loaded " .. #targets .. " target positions.")

-- Unique block types
local uniqueBlocks = getUniqueBlocks(targets)
print("Found " .. #uniqueBlocks .. " unique block types.")

-- Substitution?
io.write("Substitute block types? (y/n): ")
local substitute = (read():lower() == "y")

-- Build slot mapping
local slotMap = buildSlotMap(uniqueBlocks, substitute)

-- Breaking?
io.write("Break existing blocks that are not the target type? (y/n): ")
breakBlocks = (read():lower() == "y")
local diamondSlot = nil
if breakBlocks then
    diamondSlot = findDiamondPickaxe()
    if not diamondSlot then
        print("WARNING: No diamond pickaxe found. You may still break blocks but it will be slow.")
        io.write("Continue without diamond pickaxe? (y/n): ")
        if read():lower() ~= "y" then return end
    else
        print("Found diamond pickaxe in slot " .. diamondSlot)
        turtle.select(diamondSlot)
    end
end

-- Fuel check
local fuelNeeded = 0
for _, t in ipairs(targets) do
    fuelNeeded = fuelNeeded + math.abs(t.x - currentX) + math.abs(t.y - currentY) + math.abs(t.z - currentZ)
end
fuelNeeded = fuelNeeded + 2 * #targets -- extra for turns and pl
if turtle.getFuelLevel() < fuelNeeded then
    print("Estimated fuel needed: " .. fuelNeeded)
    io.write("Proceed anyway? (y/n): ")
    if read():lower() ~= "y" then return end
end

-- Confirm
print("Total blocks to place: " .. #targets)
io.write("Start printing? (y/n): ")
if read():lower() ~= "y" then return end

-- Main loop
local placed = 0
for i, t in ipairs(targets) do
    print(string.format("[%d/%d] Placing %s at (%d,%d,%d)", i, #targets, t.block, t.x, t.y, t.z))
    if placeAtTarget(t, slotMap, breakBlocks) then
        placed = placed + 1
    else
        print("Failed to place at " .. t.x .. "," .. t.y .. "," .. t.z)
    end
    -- Optional delay
    sleep(0.1)
end

print("Done! Placed " .. placed .. " out of " .. #targets .. " blocks.")
