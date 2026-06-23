-- Chunk Grid Navigator for Advanced Pocket Computer
-- Displays a color-coded grid of chunk boundaries (every 16 blocks)
-- centered on your current position. Works with GPS or manual movement.

-- ========== Configuration ==========
local MAP_SIZE = 20          -- cells per side (each cell = 4 blocks)
local BLOCKS_PER_CELL = 4    -- each cell represents 4x4 blocks
local CHUNK_SIZE = 16
local UPDATE_INTERVAL = 0.5  -- seconds between GPS updates

-- ========== Screen layout ==========
local MAP_LEFT = 1
local MAP_TOP = 3
local MAP_RIGHT = MAP_LEFT + MAP_SIZE - 1
local MAP_BOTTOM = MAP_TOP + MAP_SIZE - 1

-- ========== Colors ==========
local COL_BG = colors.black
local COL_GRID = colors.gray
local COL_BORDER = colors.lightGray
local COL_PLAYER = colors.red
local COL_TEXT = colors.white
local COL_INFO = colors.lightBlue

-- ========== State ==========
local posX, posZ = 0, 0
local useGPS = false
local running = true

-- ========== Helper functions ==========
function getGPSPosition()
    -- Try to get a GPS fix, timeout after 5 seconds
    if not peripheral.find("modem") then
        return nil, "No modem found"
    end
    local x, y, z = gps.locate(5)
    if x then
        return x, z  -- we only care about X and Z
    else
        return nil, "GPS fix failed"
    end
end

function chunkCoord(coord)
    -- Returns chunk coordinate and offset within chunk
    local chunk = math.floor(coord / CHUNK_SIZE)
    local offset = coord % CHUNK_SIZE
    -- Lua's % for negative numbers gives positive remainder,
    -- but we want offset in [0, CHUNK_SIZE-1]
    if offset < 0 then offset = offset + CHUNK_SIZE end
    return chunk, offset
end

function drawMap()
    -- Clear map area with background color
    for row = MAP_TOP, MAP_BOTTOM do
        term.setCursorPos(MAP_LEFT, row)
        for col = MAP_LEFT, MAP_RIGHT do
            term.setBackgroundColor(COL_BG)
            term.write(" ")
        end
    end

    -- Draw grid: iterate over each cell
    local halfSize = (MAP_SIZE * BLOCKS_PER_CELL) / 2
    local centerX = posX
    local centerZ = posZ

    for col = 0, MAP_SIZE - 1 do
        for row = 0, MAP_SIZE - 1 do
            -- Calculate world coordinates at the center of this cell
            local wx = centerX - halfSize + col * BLOCKS_PER_CELL + BLOCKS_PER_CELL/2
            local wz = centerZ - halfSize + row * BLOCKS_PER_CELL + BLOCKS_PER_CELL/2

            -- Determine if this cell is on a chunk boundary
            local onBoundaryX = false
            local onBoundaryZ = false
            -- Check if the cell crosses a multiple of CHUNK_SIZE
            local cellLeft = wx - BLOCKS_PER_CELL/2
            local cellRight = wx + BLOCKS_PER_CELL/2
            local cellBottom = wz - BLOCKS_PER_CELL/2
            local cellTop = wz + BLOCKS_PER_CELL/2

            -- Check X boundaries: any multiple of CHUNK_SIZE within the cell?
            local leftChunk = math.floor(cellLeft / CHUNK_SIZE)
            local rightChunk = math.floor(cellRight / CHUNK_SIZE)
            if leftChunk ~= rightChunk then
                onBoundaryX = true
            end
            -- Same for Z
            local bottomChunk = math.floor(cellBottom / CHUNK_SIZE)
            local topChunk = math.floor(cellTop / CHUNK_SIZE)
            if bottomChunk ~= topChunk then
                onBoundaryZ = true
            end

            -- Choose color
            local bgColor = COL_BG
            if onBoundaryX or onBoundaryZ then
                bgColor = COL_GRID
            end

            -- Check if this cell contains the player's exact position
            local playerCellX = math.floor((posX - (centerX - halfSize)) / BLOCKS_PER_CELL)
            local playerCellZ = math.floor((posZ - (centerZ - halfSize)) / BLOCKS_PER_CELL)
            if col == playerCellX and row == playerCellZ then
                bgColor = COL_PLAYER
            end

            -- Draw the cell
            term.setCursorPos(MAP_LEFT + col, MAP_TOP + row)
            term.setBackgroundColor(bgColor)
            term.write(" ")
        end
    end

    -- Draw border around the map
    for row = MAP_TOP - 1, MAP_BOTTOM + 1 do
        for col = MAP_LEFT - 1, MAP_RIGHT + 1 do
            if row == MAP_TOP - 1 or row == MAP_BOTTOM + 1 or col == MAP_LEFT - 1 or col == MAP_RIGHT + 1 then
                term.setCursorPos(col, row)
                term.setBackgroundColor(COL_BORDER)
                term.write(" ")
            end
        end
    end

    -- Draw info panel (above map)
    local cx, ox = chunkCoord(posX)
    local cz, oz = chunkCoord(posZ)
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.black)
    term.setTextColor(COL_INFO)
    term.clearLine()
    term.write("Chunk: " .. cx .. "," .. cz .. "  Offset: " .. ox .. "," .. oz)
    term.setCursorPos(1, 2)
    term.clearLine()
    term.setTextColor(COL_TEXT)
    term.write(string.format("Pos: %.1f, %.1f", posX, posZ))
    if useGPS then
        term.setTextColor(colors.green)
        term.write("  [GPS]")
    else
        term.setTextColor(colors.yellow)
        term.write("  [Manual]")
    end
    term.setTextColor(COL_TEXT)
    term.write("  Q=quit")
end

-- ========== Manual movement handler ==========
function handleManualInput()
    while running do
        drawMap()
        local event, key = os.pullEvent("key")
        if key == keys.q then
            running = false
            break
        elseif key == keys.w then
            posZ = posZ + 1
        elseif key == keys.s then
            posZ = posZ - 1
        elseif key == keys.a then
            posX = posX - 1
        elseif key == keys.d then
            posX = posX + 1
        end
    end
end

-- ========== GPS auto‑update loop ==========
function handleGPSLoop()
    while running do
        local x, z = getGPSPosition()
        if x then
            posX, posZ = x, z
            drawMap()
        else
            -- If GPS fails, show error but keep trying
            term.setCursorPos(1, 1)
            term.setTextColor(colors.red)
            term.clearLine()
            term.write("GPS lost, retrying...")
            sleep(1)
        end
        sleep(UPDATE_INTERVAL)
    end
end

-- ========== Main ==========
function main()
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(COL_TEXT)
    print("Chunk Grid Navigator")
    print("Initialising...")

    -- Try GPS first
    local x, z = getGPSPosition()
    if x then
        posX, posZ = x, z
        useGPS = true
        term.setTextColor(colors.green)
        print("GPS acquired at " .. string.format("%.1f, %.1f", posX, posZ))
        sleep(1)
        -- Start GPS loop
        handleGPSLoop()
    else
        -- Fallback to manual input
        useGPS = false
        term.setTextColor(colors.yellow)
        print("GPS unavailable.")
        print("Enter your starting coordinates:")
        write("X: ")
        posX = tonumber(read()) or 0
        write("Z: ")
        posZ = tonumber(read()) or 0
        print("Use WASD to move, Q to quit.")
        sleep(1)
        handleManualInput()
    end

    -- Clean exit
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(COL_TEXT)
    print("Chunk Navigator closed.")
end

-- Run it
main()
