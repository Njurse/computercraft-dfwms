-- ============================================================
--  pocket_client.lua  |  ComputerCraft Schematic Builder
--  Run on a Pocket Computer with a wireless modem upgrade.
--  Lets you discover turtles, load/paste schematics, align
--  the build origin, and stream the schematic to the turtle.
-- ============================================================

local CHANNEL    = 7777   -- turtle listens here for discovers
local CHANNEL_RX = 7778   -- we listen for replies here

-- ── Pocket screen is 26×20 on most CC versions ──────────────
local W, H = term.getSize()

-- ── Colours (fallback to mono gracefully) ───────────────────
local COL = {
    bg      = colours.black,
    header  = colours.blue,
    headerT = colours.white,
    panel   = colours.grey,
    panelT  = colours.white,
    accent  = colours.cyan,
    ok      = colours.green,
    warn    = colours.yellow,
    err     = colours.red,
    dim     = colours.lightGrey,
    white   = colours.white,
}
local function setFG(c) if term.isColour() then term.setTextColour(c)   end end
local function setBG(c) if term.isColour() then term.setBackgroundColour(c) end end

-- ── Modem ────────────────────────────────────────────────────

local function findModem()
    for _, side in ipairs({"top","bottom","left","right","front","back"}) do
        if peripheral.getType(side) == "modem" then
            local m = peripheral.wrap(side)
            if m.isWireless and m.isWireless() then return m end
        end
    end
    return nil
end

local modem = findModem()
if not modem then
    error("No wireless modem found on pocket computer!", 0)
end
modem.open(CHANNEL_RX)

-- ── State ────────────────────────────────────────────────────

local turtles     = {}     -- discovered: {id, label, gps, fuel}
local selTurtle   = nil    -- currently selected turtle entry
local schematic   = nil    -- loaded block list
local schem_name  = ""
local statusLog   = {}     -- last few status lines
local screen      = "home" -- home | discover | schematic | align | build

local FACINGS = {"north","east","south","west"}

local alignConfig = {
    facing   = "north",
    originGPS = nil,   -- nil = use turtle's current GPS position
}

-- ── Helpers ──────────────────────────────────────────────────

local function pushLog(msg)
    table.insert(statusLog, msg)
    if #statusLog > 6 then table.remove(statusLog, 1) end
end

local function send(tbl)
    if not selTurtle then return false end
    modem.transmit(selTurtle.channel, CHANNEL_RX, tbl)
    return true
end

local function waitReply(timeout)
    local timer = os.startTimer(timeout or 5)
    while true do
        local ev, p1, ch, _, msg = os.pullEvent()
        if ev == "modem_message" and ch == CHANNEL_RX and type(msg)=="table" then
            return msg
        elseif ev == "timer" and p1 == timer then
            return nil
        end
    end
end

-- ── Drawing helpers ──────────────────────────────────────────

local function cls()
    setBG(COL.bg); term.clear(); term.setCursorPos(1,1)
end

local function header(title)
    setBG(COL.header); setFG(COL.headerT)
    term.clearLine(); term.setCursorPos(1,1)
    local pad = math.floor((W - #title) / 2)
    term.write((" "):rep(pad) .. title)
    setBG(COL.bg); setFG(COL.white)
    term.setCursorPos(1,2)
end

local function box(y, label, value, valCol)
    term.setCursorPos(1, y)
    setFG(COL.dim); term.write(label .. ": ")
    setFG(valCol or COL.white); term.write(tostring(value or "—"))
    setFG(COL.white)
end

local function menuItem(y, key, label, active)
    term.setCursorPos(1, y)
    if active then setFG(COL.accent) else setFG(COL.dim) end
    term.write("[" .. key .. "] ")
    setFG(COL.white); term.write(label)
end

-- ── Screen: HOME ─────────────────────────────────────────────

local function drawHome()
    cls(); header("  CC Builder  ")
    local t = selTurtle
    box(3,  "Turtle",   t and t.label or "none", t and COL.ok or COL.warn)
    box(4,  "Schematic", schem_name ~= "" and schem_name or "none",
            schematic and COL.ok or COL.warn)
    box(5,  "Facing",   alignConfig.facing, COL.accent)

    local gStr = alignConfig.originGPS
        and ("%d,%d,%d"):format(
            alignConfig.originGPS.x,
            alignConfig.originGPS.y,
            alignConfig.originGPS.z)
        or "turtle pos"
    box(6, "Origin", gStr, COL.dim)

    term.setCursorPos(1, 8); setFG(COL.dim)
    term.write(("─"):rep(W))

    menuItem(9,  "D", "Discover Turtles", true)
    menuItem(10, "S", "Load Schematic",   true)
    menuItem(11, "A", "Align Turtle",     t ~= nil)
    menuItem(12, "B", "Start Build",      t ~= nil and schematic ~= nil)
    menuItem(13, "T", "Turtle Status",    t ~= nil)
    menuItem(H,  "Q", "Quit",             true)

    term.setCursorPos(1, 15); setFG(COL.dim); term.write("Log:")
    for i, line in ipairs(statusLog) do
        term.setCursorPos(1, 15 + i)
        setFG(COL.dim); term.write(line:sub(1, W))
    end
end

-- ── Screen: DISCOVER ─────────────────────────────────────────

local function doDiscover()
    cls(); header(" Discovering… ")
    term.setCursorPos(1,3); setFG(COL.accent)
    term.write("Broadcasting on ch " .. CHANNEL .. "…")

    turtles = {}
    modem.transmit(CHANNEL, CHANNEL_RX, {type="DISCOVER"})

    local deadline = os.clock() + 4
    while os.clock() < deadline do
        local timer = os.startTimer(0.5)
        local ev, p1, ch, repCh, msg = os.pullEvent()
        if ev == "modem_message" and ch == CHANNEL_RX
           and type(msg) == "table" and msg.type == "ANNOUNCE" then
            -- store which channel to reply on
            msg.channel = repCh
            table.insert(turtles, msg)
            term.setCursorPos(1, 4 + #turtles)
            setFG(COL.ok)
            term.write(("[%d] %s  fuel:%s"):format(
                #turtles, msg.label, tostring(msg.fuel)))
        end
    end

    if #turtles == 0 then
        term.setCursorPos(1,5); setFG(COL.err)
        term.write("No turtles found!")
        sleep(2); return
    end

    term.setCursorPos(1, 5 + #turtles); setFG(COL.white)
    term.write("Select [1-" .. #turtles .. "] or [0] cancel: ")
    local choice = tonumber(io.read())
    if choice and choice >= 1 and choice <= #turtles then
        selTurtle = turtles[choice]
        pushLog("Selected: " .. selTurtle.label)
    end
end

-- ── Screen: SCHEMATIC LOADER ─────────────────────────────────
--
--  Schematics are Lua files that return a table like:
--
--    return {
--      name = "My House",
--      blocks = {
--        {rx=0, ry=0, rz=0, block="minecraft:stone"},
--        {rx=1, ry=0, rz=0, block="minecraft:stone"},
--        ...
--      }
--    }
--
--  rx,ry,rz are relative to origin (0=turtle start), facing = +rz (north by default).

local BUILTIN_SCHEMATICS = {
    -- A simple 3×3×3 hollow cube for testing
    ["test_cube"] = (function()
        local blocks = {}
        for x = 0, 2 do
          for y = 0, 2 do
            for z = 0, 2 do
              local shell = (x==0 or x==2 or y==0 or y==2 or z==0 or z==2)
              if shell then
                table.insert(blocks, {rx=x, ry=y, rz=z, block="minecraft:stone"})
              end
            end
          end
        end
        return {name="Test Cube (3x3x3 hollow)", blocks=blocks}
    end)(),
    -- A 5-block cross on the ground
    ["cross"] = (function()
        local b = "minecraft:oak_planks"
        return { name="Cross (5 blocks)", blocks={
            {rx=0,ry=0,rz=0,block=b},
            {rx=1,ry=0,rz=0,block=b},
            {rx=-1,ry=0,rz=0,block=b},
            {rx=0,ry=0,rz=1,block=b},
            {rx=0,ry=0,rz=-1,block=b},
        }}
    end)(),
}

local function loadSchematic()
    cls(); header("Load Schematic")

    local i = 1
    local keys = {}
    for k in pairs(BUILTIN_SCHEMATICS) do
        term.setCursorPos(1, 2 + i)
        setFG(COL.accent); term.write("[" .. i .. "] ")
        setFG(COL.white);  term.write(BUILTIN_SCHEMATICS[k].name)
        table.insert(keys, k)
        i = i + 1
    end

    term.setCursorPos(1, 2 + i); setFG(COL.accent); term.write("[" .. i .. "] ")
    setFG(COL.white); term.write("Load from file…")
    local fileIdx = i

    term.setCursorPos(1, 2 + i + 1); setFG(COL.dim); term.write("[0] Cancel")

    term.setCursorPos(1, H - 1); setFG(COL.white)
    term.write("Choice: ")
    local choice = tonumber(io.read())
    if not choice or choice == 0 then return end

    if choice <= #keys then
        local key = keys[choice]
        local s = BUILTIN_SCHEMATICS[key]
        schematic = s.blocks
        schem_name = s.name
        pushLog("Loaded: " .. schem_name .. " (" .. #schematic .. " blocks)")
    elseif choice == fileIdx then
        term.setCursorPos(1, H - 2); term.write("Filename: ")
        local fname = io.read()
        if fname and fname ~= "" then
            local ok, data = pcall(dofile, fname)
            if ok and data and data.blocks then
                schematic = data.blocks
                schem_name = data.name or fname
                pushLog("Loaded file: " .. schem_name)
            else
                pushLog("ERR loading file: " .. tostring(data))
                sleep(2)
            end
        end
    end
end

-- ── Schematic rotation ───────────────────────────────────────
-- Default schematic facing is NORTH (+Z = forward for turtle facing north).
-- If the turtle will face a different direction we rotate.

local function rotateSchematic(blocks, fromFacing, toFacing)
    -- How many 90° CW turns from fromFacing to toFacing?
    local order = {north=0, east=1, south=2, west=3}
    local turns = (order[toFacing] - order[fromFacing]) % 4
    local result = {}
    for _, b in ipairs(blocks) do
        local x, z = b.rx, b.rz
        for _ = 1, turns do
            -- 90° CW: (x,z) → (z, -x)  (in "standard" right-hand, here adapted for CC)
            x, z = -z, x
        end
        table.insert(result, {rx=x, ry=b.ry, rz=z, block=b.block})
    end
    return result
end

-- ── Screen: ALIGN ────────────────────────────────────────────

local function doAlign()
    if not selTurtle then pushLog("No turtle selected"); return end
    cls(); header("Align Turtle")

    local fIdx = 1
    for i, f in ipairs(FACINGS) do
        if f == alignConfig.facing then fIdx = i; break end
    end

    term.setCursorPos(1,3)
    term.write("Turtle will face: ")
    setFG(COL.accent); term.write(alignConfig.facing); setFG(COL.white)

    term.setCursorPos(1,4)
    term.write("(build goes in +Z from turtle)")

    term.setCursorPos(1,6)
    setFG(COL.dim); term.write("[L/R] rotate facing  [G] use GPS pos")
    term.setCursorPos(1,7)
    setFG(COL.dim); term.write("[M] manual GPS  [A] send align  [0] back")

    if alignConfig.originGPS then
        local g = alignConfig.originGPS
        term.setCursorPos(1,9)
        setFG(COL.white); term.write("Origin: ")
        setFG(COL.accent)
        term.write(("%d,%d,%d"):format(g.x,g.y,g.z))
        setFG(COL.white)
    else
        term.setCursorPos(1,9)
        setFG(COL.dim); term.write("Origin: turtle's current GPS")
    end

    term.setCursorPos(1, H-1); term.write("> ")
    local key = io.read()

    if key == "l" or key == "L" then
        fIdx = ((fIdx - 2) % 4) + 1
        alignConfig.facing = FACINGS[fIdx]
        doAlign(); return
    elseif key == "r" or key == "R" then
        fIdx = (fIdx % 4) + 1
        alignConfig.facing = FACINGS[fIdx]
        doAlign(); return
    elseif key == "g" or key == "G" then
        alignConfig.originGPS = nil   -- use turtle's GPS
        doAlign(); return
    elseif key == "m" or key == "M" then
        term.setCursorPos(1,11); term.write("X: "); local ox = tonumber(io.read())
        term.setCursorPos(1,12); term.write("Y: "); local oy = tonumber(io.read())
        term.setCursorPos(1,13); term.write("Z: "); local oz = tonumber(io.read())
        if ox and oy and oz then
            alignConfig.originGPS = {x=ox, y=oy, z=oz}
        end
        doAlign(); return
    elseif key == "a" or key == "A" then
        -- Send align command to turtle
        send({
            type      = "ALIGN",
            facing    = alignConfig.facing,
            originGPS = alignConfig.originGPS,
        })
        term.setCursorPos(1,11); setFG(COL.accent); term.write("Waiting for ack…")
        local reply = waitReply(10)
        if reply and reply.type == "ALIGN_ACK" then
            setFG(COL.ok)
            term.setCursorPos(1,12)
            term.write("ACK! Facing: " .. (reply.detectedFacing or "?"))
            if reply.confirmedGPS then
                local g = reply.confirmedGPS
                term.setCursorPos(1,13)
                term.write(("GPS: %d,%d,%d"):format(g.x,g.y,g.z))
            end
            pushLog("Aligned: " .. (reply.detectedFacing or "?"))
        else
            setFG(COL.err)
            term.setCursorPos(1,12); term.write("No reply / timeout!")
            pushLog("Align: no reply")
        end
        setFG(COL.white)
        sleep(2)
    elseif key == "0" then
        return
    end
end

-- ── Screen: BUILD ────────────────────────────────────────────

local function doBuild()
    if not selTurtle then pushLog("No turtle selected"); return end
    if not schematic  then pushLog("No schematic loaded"); return end

    cls(); header("Start Build")

    -- Rotate schematic to match chosen facing
    local rotated = rotateSchematic(schematic, "north", alignConfig.facing)

    box(3, "Schematic", schem_name, COL.white)
    box(4, "Blocks",    #rotated,   COL.accent)
    box(5, "Facing",    alignConfig.facing, COL.accent)
    box(6, "Turtle",    selTurtle.label, COL.ok)

    term.setCursorPos(1,8)
    setFG(COL.warn); term.write("Make sure turtle has all materials!")
    term.setCursorPos(1,9)
    setFG(COL.white); term.write("[Y] Send & Build   [0] Cancel: ")
    local c = io.read()

    if c ~= "y" and c ~= "Y" then return end

    -- Send schematic
    term.setCursorPos(1,11); setFG(COL.accent); term.write("Sending schematic…")
    send({type="LOAD_SCHEMATIC", schematic=rotated})
    local ack = waitReply(10)
    if not ack or ack.type ~= "SCHEMATIC_ACK" then
        setFG(COL.err); term.setCursorPos(1,12); term.write("Schematic send failed!")
        pushLog("Schematic send failed"); sleep(2); return
    end
    term.setCursorPos(1,12); setFG(COL.ok)
    term.write("Schematic received (" .. ack.count .. " blocks)")

    -- Start build
    sleep(0.5)
    send({type="START_BUILD"})
    local startReply = waitReply(5)
    if not startReply or startReply.type ~= "BUILD_START" then
        setFG(COL.err); term.setCursorPos(1,13); term.write("Build start failed!")
        pushLog("Build start failed"); sleep(2); return
    end

    -- Progress display
    term.setCursorPos(1,13); setFG(COL.white); term.write("Building…")
    local done = false
    while not done do
        local ev, _, ch, _, msg = os.pullEvent("modem_message")
        if ch == CHANNEL_RX and type(msg) == "table" then
            if msg.type == "PROGRESS" then
                term.setCursorPos(1,14)
                setBG(COL.bg)
                local pct = math.floor(msg.current / msg.total * 100)
                setFG(COL.accent)
                term.write(("[%d/%d] %d%%   "):format(
                    msg.current, msg.total, pct))
                -- Draw a simple progress bar
                local barW = W - 2
                local filled = math.floor(barW * msg.current / msg.total)
                term.setCursorPos(1,15)
                setBG(COL.panel); setFG(COL.ok)
                term.write(("█"):rep(filled))
                setBG(COL.bg); setFG(COL.dim)
                term.write(("░"):rep(barW - filled))
                setBG(COL.bg); setFG(COL.white)
            elseif msg.type == "BUILD_DONE" then
                done = true
                term.setCursorPos(1,16); setFG(COL.ok)
                term.write("✔ Build complete!")
                pushLog("Build done: " .. schem_name)
            elseif msg.type == "ERROR" then
                done = true
                term.setCursorPos(1,16); setFG(COL.err)
                term.write("ERROR: " .. (msg.error or "?"))
                pushLog("Build error: " .. (msg.error or "?"))
            end
        end
    end
    sleep(3)
end

-- ── Screen: STATUS ───────────────────────────────────────────

local function doStatus()
    if not selTurtle then pushLog("No turtle selected"); return end
    cls(); header("Turtle Status")
    term.setCursorPos(1,3); setFG(COL.accent); term.write("Querying…")

    send({type="STATUS"})
    local reply = waitReply(5)
    if not reply or reply.type ~= "STATUS_REPLY" then
        term.setCursorPos(1,4); setFG(COL.err); term.write("No response")
        sleep(2); return
    end

    box(3,  "Label",   reply.label, COL.white)
    box(4,  "Fuel",    (reply.fuel or "?") .. "/" .. (reply.fuelMax or "?"), COL.accent)
    box(5,  "Facing",  reply.facing, COL.accent)
    if reply.gps then
        local g = reply.gps
        box(6, "GPS", ("%d,%d,%d"):format(g.x,g.y,g.z), COL.white)
    else
        box(6, "GPS", "no fix", COL.err)
    end
    if reply.relPos then
        local p = reply.relPos
        box(7, "RelPos", ("%d,%d,%d"):format(p.x,p.y,p.z), COL.dim)
    end
    box(8, "Schematic", reply.schematic .. " blocks loaded", COL.dim)

    term.setCursorPos(1, H-1); setFG(COL.dim); term.write("[any key to return]")
    io.read()
end

-- ── Main loop ────────────────────────────────────────────────

local function main()
    while true do
        drawHome()
        term.setCursorPos(1, H); setFG(COL.white); term.write("> ")
        local key = io.read()
        local k = key:lower()

        if k == "d" then
            doDiscover()
        elseif k == "s" then
            loadSchematic()
        elseif k == "a" and selTurtle then
            doAlign()
        elseif k == "b" and selTurtle and schematic then
            doBuild()
        elseif k == "t" and selTurtle then
            doStatus()
        elseif k == "q" then
            cls(); setFG(COL.white); print("Goodbye!"); return
        end
    end
end

main()
