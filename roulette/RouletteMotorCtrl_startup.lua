-- ─────────────────────────────────────────────────────────────────────────────
-- startup/RouletteMotorCtrl_startup.lua
-- Place this file as "startup.lua" on the RouletteMotorCtrl computer.
-- ─────────────────────────────────────────────────────────────────────────────

if os.getComputerLabel() ~= "RouletteMotorCtrl" then
    os.setComputerLabel("RouletteMotorCtrl")
    print("Label set to RouletteMotorCtrl. Rebooting...")
    os.reboot()
end

print("=== Buckshot Roulette — Motor Controller ===")
shell.run("motor_ctrl.lua")
