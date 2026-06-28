-- lib/inventory.lua
-- Hardware-agnostic inventory and logistics abstraction.
-- RouletteAdmin uses this to move shells between:
--   STORAGE  → MAGAZINE  → CHAMBER (visual)  → SPENT
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
    MAGAZINE = "magazine",   -- Currently loaded shells
    SPENT    = "spent",      -- Fired shells
}

-- ── Discovery ──────────────────────────────────────────────────────────────

--- Scan all attached peripherals and find inventories.
--- Returns a table mapping role → peripheral handle, or nil + error.
---
--- Roles are assigned by the SIZE of the inventory (or by item contents):
---   Largest chest  → STORAGE
---   Medium chest   → MAGAZINE
---   Smallest chest → SPENT
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
        Inventory.ROLE.SPENT,
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

--- Move all spent shells from the MAGAZINE inventory to SPENT.
---@param roles table
---@return number moved
function Inventory.clearMagazine(roles)
    local magazine = roles[Inventory.ROLE.MAGAZINE]
    local spent    = roles[Inventory.ROLE.SPENT]
    if not magazine then return 0 end
    if spent then
        return Inventory.transferAll(magazine, spent)
    else
        -- No spent bin: just clear (items lost — warn but continue)
        print("[Inv] WARNING: No SPENT inventory found; clearing magazine items.")
        local items = magazine.list()
        for slot, _ in pairs(items) do
            pcall(function() magazine.pushItems(peripheral.getName(magazine), slot, 64) end)
        end
        return 0
    end
end

return Inventory
