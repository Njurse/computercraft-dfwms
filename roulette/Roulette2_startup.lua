-- ─────────────────────────────────────────────────────────────────────────────
-- startup/Roulette2_startup.lua
-- Place this file as "startup.lua" on the Roulette2 computer.
-- ─────────────────────────────────────────────────────────────────────────────

if os.getComputerLabel() ~= "Roulette2" then
    os.setComputerLabel("Roulette2")
    print("Label set to Roulette2. Rebooting...")
    os.reboot()
end

print("=== Buckshot Roulette — Player 2 ===")
shell.run("player.lua")
