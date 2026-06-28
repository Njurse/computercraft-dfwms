-- =========================
-- Induction Matrix Builder
-- CC:Tweaked Turtle Script
-- =========================

-- ===== CONFIG =====
local config = {
    width = 5,
    depth = 5,
    cellCount = 4,
    providerCount = 1,
    fuelSlot = 16
}

-- ===== STATE =====
local x, y, z = 0, 0, 0
local facing = 0 -- 0 north/forward, 1 east, 2 south, 3 west

-- ===== UTIL =====
local function status(msg)
    term.clear()
    term.setCursorPos(1,1)
    print("[Matrix Builder]")
    print(msg)
end

local function waitKey()
    print("\nPress any key to continue...")
    os.pullEvent("key")
end

local function ensureFuel()
    turtle.select(config.fuelSlot)
    if turtle.getFuelLevel() < 200 then
        status("Refueling...")
        if turtle.refuel(1) then
            status("Refueled successfully.")
        else
            print("No fuel found in slot " .. config.fuelSlot)
            waitKey()
        end
    end
end

local function moveForward()
    while not turtle.forward() do
        status("Blocked forward. Clear path and press key.")
        waitKey()
    end
    x = x + 1
end

local function moveUp()
    while not turtle.up() do
        status("Blocked upward. Clear above and press key.")
        waitKey()
    end
    y = y + 1
end

local function moveDown()
    while not turtle.down() do
        status("Blocked downward. Clear below and press key.")
        waitKey()
    end
    y = y - 1
end

-- ===== INVENTORY CHECK =====
local function countItem(name)
    local count = 0
    for i=1,16 do
        local data = turtle.getItemDetail(i)
        if data and data.name == name then
            count = count + turtle.getItemCount(i)
        end
    end
    return count
end

local function selectItem(name)
    for i=1,16 do
        local data = turtle.getItemDetail(i)
        if data and data.name == name then
            turtle.select(i)
            return true
        end
    end
    return false
end

local function place(blockName)
    if not selectItem(blockName) then
        status("Missing block: " .. blockName)
        waitKey()
        return false
    end
    return turtle.placeDown()
end

-- ===== BUILD HELPERS =====
local function buildLayer(yLevel, fn)
    while y < yLevel do moveUp() end
    while y > yLevel do moveDown() end

    for dz=1,config.depth do
        for dx=1,config.width do
            fn(dx, dz)
            if dx < config.width then moveForward() end
        end

        if dz < config.depth then
            if dz % 2 == 1 then
                turtle.turnRight()
                moveForward()
                turtle.turnRight()
            else
                turtle.turnLeft()
                moveForward()
                turtle.turnLeft()
            end
        end
    end
end

-- ===== BUILD MATRIX =====
local function deployMatrix()

    ensureFuel()

    local requiredCasings = config.width * config.depth * 4
    local casingName = "mekanism:basic_induction_cell" -- fallback; adjust if needed

    status("Checking inventory...")
    if countItem(casingName) < requiredCasings then
        print("Warning: Not enough casings.")
        waitKey()
    end

    -- LAYER 1
    status("Building layer 1 (bottom casings)")
    buildLayer(0, function()
        place(casingName)
    end)

    -- LAYER 2
    status("Building layer 2 (providers + ports)")

    buildLayer(1, function(xp, zp)

        local isProvider = (xp == 2 and zp == 2 and config.providerCount > 0)
        local isPortA = (xp == 1 and zp == 2)
        local isPortB = (xp == 3 and zp == 2)

        if isProvider then
            place("mekanism:induction_provider")
        elseif isPortA or isPortB then
            place("mekanism:induction_port")
        else
            place(casingName)
        end
    end)

    -- LAYER 3
    status("Building layer 3 (cells)")
    local cellsPlaced = 0

    buildLayer(2, function()
        if cellsPlaced < config.cellCount then
            place("mekanism:basic_induction_cell")
            cellsPlaced = cellsPlaced + 1
        else
            place(casingName)
        end
    end)

    -- LAYER 4
    status("Building top layer")
    buildLayer(3, function()
        place(casingName)
    end)

    status("Deployment complete.")
    waitKey()
end

-- ===== TEARDOWN =====
local function destroyMatrix()
    status("WARNING: Requires diamond pickaxe equipped.")
    print("Continue? (y/n)")
    local _, key = os.pullEvent("char")
    if key ~= "y" then return end

    for yy=3,0,-1 do
        status("Removing layer " .. yy)

        while y < yy do moveUp() end
        while y > yy do moveDown() end

        for dz=1,config.depth do
            for dx=1,config.width do
                if turtle.detectDown() then
                    turtle.digDown()
                end
                if dx < config.width then moveForward() end
            end
        end
    end

    status("Destruction complete.")
    waitKey()
end

-- ===== MENU =====
local function menu()
    while true do
        term.clear()
        term.setCursorPos(1,1)
        print("=== Induction Matrix Turtle ===")
        print("1. Deploy Matrix")
        print("2. Destroy Matrix")
        print("3. Exit")
        print("\nSelect option:")

        local event, key = os.pullEvent("char")

        if key == "1" then
            deployMatrix()
        elseif key == "2" then
            destroyMatrix()
        elseif key == "3" then
            return
        end
    end
end

menu()
