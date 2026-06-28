-- ─────────────────────────────────────────────────────────────────────────────
-- startup/Roulette1_startup.lua
-- Place this file as "startup.lua" on the Roulette1 computer.
-- ─────────────────────────────────────────────────────────────────────────────

if os.getComputerLabel() ~= "Roulette1" then
    os.setComputerLabel("Roulette1")
    print("Label set to Roulette1. Rebooting...")
    os.reboot()
end

print("=== Buckshot Roulette — Player 1 ===")
shell.run("player.lua")
