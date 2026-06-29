-- lib/inventory.lua
-- Hardware-agnostic inventory and logistics abstraction.
-- RouletteAdmin uses this to move shells between:
--   STORAGE  → MAGAZINE  → CHAMBER (visual display of currently loaded shell)
--
-- Supports:
--   • Vanilla chests / barrels (inventory peripheral)
--   • Create Depots            (inventory peripheral)
--   • Any peripheral exposing .list() / .getItemDetail() / .pushItems() / .pullItems()
--
-- The transport mechanism (belts, funnels, arms, Mekanism transporters) is external.
-- This module only manages the software-side of inventory state.
-- Physical movement is triggered by calling the motor controller or
-- by toggling redstone signals — not handled here.

local Inventory = {}

-- ── Role labels (used as keys in the peripheral table) ─────────────────────
Inventory.ROLE = {
    STORAGE  = "storage",    -- Unused ammunition reserve
    MAGAZINE = "magazine",   -- Shells loaded for the current round
    CHAMBER  = "chamber",    -- Single-type drawer showing the currently chambered shell
}

-- ── Discovery ──────────────────────────────────────────────────────────────

--- Scan all attached peripherals and find inventories.
--- Returns a table mapping role → peripheral handle, or nil + error.
---
--- Roles are assigned by the SIZE of the inventory:
---   Largest chest   → STORAGE  (holds all spare shells)
---   Medium chest    → MAGAZINE (holds 2-8 shells for the round)
---   Smallest/single → CHAMBER  (1-slot drawer showing the loaded shell)
---
--- If only one inventory is found it is assigned STORAGE and the game proceeds
--- in software-only mode (items not physically moved).
---
---@return table|nil roles, string|nil err
function Inventory.discoverInventories()
    local found = {}

    -- peripheral.find returns all matching peripherals
    local inventories = { peripheral.find("inventory") }
    for _, inv in ipairs(inventories) do
        local name = peripheral.getName(inv)
        local size = inv.size and inv.size() or 0
        table.insert(found, { name = name, handle = inv, size = size })
    end

    if #found == 0 then
        return nil, "No inventory peripherals found."
    end

    -- Sort descending by slot count so the biggest = STORAGE
    table.sort(found, function(a, b) return a.size > b.size end)

    local roles = {}
    local roleOrder = {
        Inventory.ROLE.STORAGE,
        Inventory.ROLE.MAGAZINE,
        Inventory.ROLE.CHAMBER,
    }
    for i, entry in ipairs(found) do
        local role = roleOrder[i] or ("extra_" .. i)
        roles[role] = entry.handle
        print("[Inv] Assigned " .. entry.name .. " (size=" .. entry.size .. ") as " .. role)
    end

    return roles, nil
end

-- ── Counting ───────────────────────────────────────────────────────────────

--- Count items of a given item ID in an inventory.
---@param inv    table  peripheral handle
---@param itemId string Minecraft item ID (e.g. "mekanism:infused_alloy")
---@return number
function Inventory.count(inv, itemId)
    if not inv then return 0 end
    local total = 0
    local items = inv.list()
    for _, stack in pairs(items) do
        if stack.name == itemId then
            total = total + stack.count
        end
    end
    return total
end

--- List all items in an inventory as { slot, name, count } entries.
---@param inv table
---@return table
function Inventory.listItems(inv)
    if not inv then return {} end
    local result = {}
    local items  = inv.list()
    for slot, stack in pairs(items) do
        table.insert(result, { slot = slot, name = stack.name, count = stack.count })
    end
    return result
end

-- ── Transfer ───────────────────────────────────────────────────────────────

--- Move `count` items of `itemId` from `srcInv` to `dstInv`.
--- Returns the number of items actually moved, or 0 on failure.
---
--- Uses pushItems(dstName, srcSlot, count) which is supported by most
--- ComputerCraft inventory peripherals.
---
---@param srcInv table  source peripheral
---@param dstInv table  destination peripheral
---@param itemId string Minecraft item ID
---@param count  number
---@return number moved
function Inventory.transfer(srcInv, dstInv, itemId, count)
    if not srcInv or not dstInv then return 0 end

    local dstName = peripheral.getName(dstInv)
    local moved   = 0
    local items   = srcInv.list()

    for slot, stack in pairs(items) do
        if moved >= count then break end
        if stack.name == itemId then
            local toMove = math.min(count - moved, stack.count)
            local ok, transferred = pcall(function()
                return srcInv.pushItems(dstName, slot, toMove)
            end)
            if ok and transferred then
                moved = moved + transferred
            end
        end
    end

    return moved
end

--- Move ALL items from `srcInv` to `dstInv` (any item type).
---@param srcInv table
---@param dstInv table
---@return number totalMoved
function Inventory.transferAll(srcInv, dstInv)
    if not srcInv or not dstInv then return 0 end

    local dstName = peripheral.getName(dstInv)
    local total   = 0
    local items   = srcInv.list()

    for slot, stack in pairs(items) do
        local ok, moved = pcall(function()
            return srcInv.pushItems(dstName, slot, stack.count)
        end)
        if ok and moved then
            total = total + moved
        end
    end

    return total
end

-- ── Magazine Loading ───────────────────────────────────────────────────────

--- Load shells into the magazine inventory according to a shell list.
--- The shell list is the logical order (from generateMagazine).
--- Items are moved from STORAGE into MAGAZINE one by one.
---
--- Returns true on full success, false + reason on partial failure.
---
---@param roles      table   from discoverInventories()
---@param shellList  table   list of GameState.SHELL.* strings
---@param shellItems table   GameState.SHELL_ITEMS mapping
---@return boolean, string|nil
function Inventory.loadMagazine(roles, shellList, shellItems)
    local storage = roles[Inventory.ROLE.STORAGE]
    local magazine = roles[Inventory.ROLE.MAGAZINE]

    if not storage or not magazine then
        return false, "Storage or magazine inventory missing."
    end

    -- Count what we need
    local needed = {}
    for _, shell in ipairs(shellList) do
        local id = shellItems[shell]
        needed[id] = (needed[id] or 0) + 1
    end

    -- Verify stock
    for id, qty in pairs(needed) do
        local available = Inventory.count(storage, id)
        if available < qty then
            return false, "Not enough " .. id .. " in storage (need " .. qty .. ", have " .. available .. ")."
        end
    end

    -- Move items
    for _, shell in ipairs(shellList) do
        local id    = shellItems[shell]
        local moved = Inventory.transfer(storage, magazine, id, 1)
        if moved < 1 then
            return false, "Failed to move " .. id .. " to magazine."
        end
        sleep(0.1)  -- brief yield between transfers
    end

    return true, nil
end

--- Move all leftover shells from the MAGAZINE back to STORAGE.
--- Called at the start of each round to clear the old magazine.
---@param roles table
---@return number moved
function Inventory.clearMagazine(roles)
    local magazine = roles[Inventory.ROLE.MAGAZINE]
    local storage  = roles[Inventory.ROLE.STORAGE]
    if not magazine then return 0 end

    if storage and storage ~= magazine then
        print("[Inv] Clearing leftover shells from magazine back to storage.")
        return Inventory.transferAll(magazine, storage)
    else
        print("[Inv] WARNING: No STORAGE to return leftover shells; they will be lost.")
        local items = magazine.list()
        for slot, _ in pairs(items) do
            print("[Inv] Slot " .. slot .. " has leftover items (no target to move to).")
        end
        return 0
    end
end

-- ── Chamber Display ────────────────────────────────────────────────────────

--- Move one shell from the MAGAZINE into the CHAMBER drawer.
--- This shows which shell is currently loaded/chambered for the turn.
---@param roles     table   from discoverInventories()
---@param shellItem string  Minecraft item ID (e.g. "mekanism:infused_alloy")
---@return boolean, string|nil
function Inventory.loadChamber(roles, shellItem)
    local magazine = roles[Inventory.ROLE.MAGAZINE]
    local chamber  = roles[Inventory.ROLE.CHAMBER]
    if not magazine then
        return false, "Magazine inventory missing."
    end
    if not chamber then
        print("[Inv] No CHAMBER drawer configured; running headless.")
        return true, nil  -- not a fatal error
    end

    -- Move one shell of the matching type from magazine to chamber
    local moved = Inventory.transfer(magazine, chamber, shellItem, 1)
    if moved < 1 then
        return false, "Failed to move " .. shellItem .. " from magazine to chamber."
    end
    print("[Inv] Chambered: " .. shellItem)
    return true, nil
end

--- Remove the shell from the CHAMBER drawer after firing.
--- Pushes it back to STORAGE (or voids it if no STORAGE).
---@param roles table
function Inventory.clearChamber(roles)
    local chamber = roles[Inventory.ROLE.CHAMBER]
    local storage = roles[Inventory.ROLE.STORAGE]
    if not chamber then return end

    local items = chamber.list()
    if not items or next(items) == nil then
        return  -- nothing to clear
    end

    if storage and storage ~= chamber then
        print("[Inv] Clearing chamber back to storage.")
        Inventory.transferAll(chamber, storage)
    else
        print("[Inv] Chamber item cleared (no STORAGE to return it to).")
    end
end

return Inventory
