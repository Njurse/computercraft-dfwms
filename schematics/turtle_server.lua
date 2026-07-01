-- ============================================================
--  turtle_server.lua  |  ComputerCraft Schematic Builder
--  Place this on a turtle that has:
--    • A wireless modem (any side)
--    • Enough inventory to hold building materials
--  The turtle uses GPS for positioning and movement tracking.
-- ============================================================

local CHANNEL    = 7777   -- main comms channel
local CHANNEL_RX = 7778   -- turtle listens here for replies

-- ── Helpers ─────────────────────────────────────────────────

local function findModem()
    for _, side in ipairs({"top","bottom","left","right","front","back"}) do
        if peripheral.getType(side) == "modem" then
            local m = peripheral.wrap(side)
            if m.isWireless and m.isWireless() then return m, side end
        end
    end
    return nil
end

local function log(msg)
    print("[SERVER] " .. tostring(msg))
end

-- ── GPS + Facing ─────────────────────────────────────────────

local function gpsLocate()
    local x, y, z = gps.locate(3)
    if x then return {x=math.floor(x+0.5), y=math.floor(y+0.5), z=math.floor(z+0.5)} end
    return nil
end

-- Determine facing by moving forward one block and comparing GPS.
-- Returns "north"(z-1), "south"(z+1), "east"(x+1), "west"(x-1), or nil.
local function detectFacing()
    local before = gpsLocate()
    if not before then return nil end
    if not turtle.forward() then return nil end
    local after = gpsLocate()
    if not turtle.back() then
        -- couldn't come back – just stay and note this
        log("WARNING: couldn't return after facing detect")
    end
    if not after then return nil end
    local dx = after.x - before.x
    local dz = after.z - before.z
    if     dx ==  1 then return "east"
    elseif dx == -1 then return "west"
    elseif dz ==  1 then return "south"
    elseif dz == -1 then return "north"
    end
    return nil
end

-- ── Movement with GPS tracking ───────────────────────────────

local pos     = {x=0, y=0, z=0}
local facing  = "north"   -- will be confirmed at runtime

local FACE_DX = { north=0,  south=0,  east=1,  west=-1 }
local FACE_DZ = { north=-1, south=1,  east=0,  west=0  }

local TURN_LEFT  = { north="west",  west="south", south="east", east="north" }
local TURN_RIGHT = { north="east",  east="south", south="west", west="north" }

local function moveForward()
    if turtle.forward() then
        pos.x = pos.x + FACE_DX[facing]
        pos.z = pos.z + FACE_DZ[facing]
        return true
    end
    return false
end

local function moveBack()
    if turtle.back() then
        pos.x = pos.x - FACE_DX[facing]
        pos.z = pos.z - FACE_DZ[facing]
        return true
    end
    return false
end

local function moveUp()
    if turtle.up() then pos.y = pos.y + 1; return true end
    return false
end

local function moveDown()
    if turtle.down() then pos.y = pos.y - 1; return true end
    return false
end

local function turnLeft()
    turtle.turnLeft(); facing = TURN_LEFT[facing]
end

local function turnRight()
    turtle.turnRight(); facing = TURN_RIGHT[facing]
end

-- Face a target direction
local function faceDir(target)
    if facing == target then return end
    -- Try one right turn first
    local tmp = TURN_RIGHT[facing]
    if tmp == target then turnRight(); return end
    tmp = TURN_LEFT[facing]
    if tmp == target then turnLeft(); return end
    -- 180°
    turnRight(); turnRight()
end

-- ── Navigation: go to relative {x,y,z} from origin ──────────

local function goTo(tx, ty, tz)
    -- Y first (go up before navigating to avoid ground obstacles)
    while pos.y < ty do if not moveUp()    then return false end end
    -- X axis
    if tx > pos.x then
        faceDir("east")
        while pos.x < tx do if not moveForward() then return false end end
    elseif tx < pos.x then
        faceDir("west")
        while pos.x > tx do if not moveForward() then return false end end
    end
    -- Z axis
    if tz > pos.z then
        faceDir("south")
        while pos.z < tz do if not moveForward() then return false end end
    elseif tz < pos.z then
        faceDir("north")
        while pos.z > tz do if not moveForward() then return false end end
    end
    -- Y down (after X/Z so we don't dig ourselves in)
    while pos.y > ty do if not moveDown()   then return false end end
    return true
end

-- ── Inventory: find a slot with the given item name ─────────

local function selectBlock(name)
    for i = 1, 16 do
        local info = turtle.getItemDetail(i)
        if info and info.name == name then
            turtle.select(i)
            return true
        end
    end
    return false
end

-- ── Building ─────────────────────────────────────────────────

-- Schematic is a list of {rx, ry, rz, block} entries.
-- rx/ry/rz are relative to the turtle's ORIGIN (GPS position when aligned).
-- Rotation is baked in by the client before sending.

local function buildSchematic(schematic, modem, clientChannel)
    local total = #schematic
    log("Building " .. total .. " blocks…")

    -- Sort: bottom layers first, then by X then Z (snake pattern)
    table.sort(schematic, function(a, b)
        if a.ry ~= b.ry then return a.ry < b.ry end
        if a.rx ~= b.rx then return a.rx < b.rx end
        return a.rz < b.rz
    end)

    for i, entry in ipairs(schematic) do
        local tx, ty, tz = entry.rx, entry.ry, entry.rz
        local blockName  = entry.block

        -- Navigate to one block below/above placement position
        -- We place blocks *below* us (placeDown) when y matches,
        -- or *in front* (place) for same-level — strategy: go to y+1 and placeDown
        local nav = goTo(tx, ty + 1, tz)
        if not nav then
            log("Navigation failed at " .. tx .. "," .. ty .. "," .. tz)
        else
            if not selectBlock(blockName) then
                log("MISSING block: " .. blockName)
            else
                turtle.placeDown()
            end
        end

        -- Report progress every 10 blocks
        if i % 10 == 0 or i == total then
            modem.transmit(clientChannel, CHANNEL_RX, {
                type    = "PROGRESS",
                current = i,
                total   = total,
            })
        end
    end

    -- Return home
    goTo(0, 0, 0)
    modem.transmit(clientChannel, CHANNEL_RX, {type="BUILD_DONE"})
    log("Build complete!")
end

-- ── Main ─────────────────────────────────────────────────────

local function main()
    local modem, side = findModem()
    if not modem then
        error("No wireless modem found! Attach one and restart.", 0)
    end
    modem.open(CHANNEL_RX)
    log("Listening on channel " .. CHANNEL_RX .. "  (announces on " .. CHANNEL .. ")")

    -- Initial GPS fix
    local gpsPos = gpsLocate()
    if gpsPos then
        log(("GPS fix: %d,%d,%d"):format(gpsPos.x, gpsPos.y, gpsPos.z))
    else
        log("WARNING: No GPS fix – alignment will be manual only")
    end

    local clientChannel = nil
    local schematic     = nil
    local originGPS     = nil   -- GPS coords of build origin (set during ALIGN)
    local originFacing  = nil   -- confirmed facing at alignment

    while true do
        local _, _, ch, repCh, msg = os.pullEvent("modem_message")
        if ch == CHANNEL_RX and type(msg) == "table" then

            -- ── DISCOVER: pocket computer looking for turtles
            if msg.type == "DISCOVER" then
                clientChannel = repCh
                local myGPS = gpsLocate()
                modem.transmit(clientChannel, CHANNEL_RX, {
                    type    = "ANNOUNCE",
                    id      = os.getComputerID(),
                    label   = os.getComputerLabel() or ("Turtle#"..os.getComputerID()),
                    gps     = myGPS,
                    fuel    = turtle.getFuelLevel(),
                    fuelMax = turtle.getFuelLimit(),
                })
                log("Announced to client on ch " .. clientChannel)

            -- ── ALIGN: client tells us where origin is + what facing to adopt
            elseif msg.type == "ALIGN" then
                clientChannel = repCh
                originGPS     = msg.originGPS    -- {x,y,z} in world coords
                originFacing  = msg.facing        -- "north"/"south"/"east"/"west"

                -- Detect actual facing via GPS movement
                log("Detecting facing via GPS…")
                local detectedFacing = detectFacing()
                if detectedFacing then
                    facing = detectedFacing
                    log("Detected facing: " .. facing)
                else
                    log("GPS facing detect failed – trusting client facing: " .. (originFacing or "?"))
                    facing = originFacing or "north"
                end

                -- Reset relative position to (0,0,0)
                pos = {x=0, y=0, z=0}

                -- Turn to match the requested facing
                faceDir(originFacing)

                modem.transmit(clientChannel, CHANNEL_RX, {
                    type           = "ALIGN_ACK",
                    detectedFacing = facing,
                    confirmedGPS   = gpsLocate(),
                })
                log("Aligned. Facing=" .. facing)

            -- ── LOAD_SCHEMATIC: receive the block list
            elseif msg.type == "LOAD_SCHEMATIC" then
                clientChannel = repCh
                schematic = msg.schematic
                log("Received schematic: " .. #schematic .. " blocks")
                modem.transmit(clientChannel, CHANNEL_RX, {
                    type  = "SCHEMATIC_ACK",
                    count = #schematic,
                })

            -- ── START_BUILD: go!
            elseif msg.type == "START_BUILD" then
                clientChannel = repCh
                if not schematic then
                    modem.transmit(clientChannel, CHANNEL_RX, {
                        type  = "ERROR",
                        error = "No schematic loaded",
                    })
                else
                    modem.transmit(clientChannel, CHANNEL_RX, {type="BUILD_START"})
                    buildSchematic(schematic, modem, clientChannel)
                end

            -- ── STATUS: heartbeat / info request
            elseif msg.type == "STATUS" then
                clientChannel = repCh
                modem.transmit(clientChannel, CHANNEL_RX, {
                    type      = "STATUS_REPLY",
                    id        = os.getComputerID(),
                    label     = os.getComputerLabel() or ("Turtle#"..os.getComputerID()),
                    gps       = gpsLocate(),
                    relPos    = pos,
                    facing    = facing,
                    fuel      = turtle.getFuelLevel(),
                    schematic = schematic and #schematic or 0,
                })
            end
        end
    end
end

main()
