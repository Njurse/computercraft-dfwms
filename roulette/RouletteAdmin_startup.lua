-- ─────────────────────────────────────────────────────────────────────────────
-- startup/RouletteAdmin.lua
-- Place this file as "startup.lua" on the RouletteAdmin computer.
-- ─────────────────────────────────────────────────────────────────────────────
-- Sets the computer label and launches admin.lua

if os.getComputerLabel() ~= "RouletteAdmin" then
    os.setComputerLabel("RouletteAdmin")
    print("Label set to RouletteAdmin. Rebooting...")
    os.reboot()
end

print("=== Buckshot Roulette — Admin ===")
shell.run("admin.lua")
