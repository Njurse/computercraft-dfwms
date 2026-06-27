-- reactor_scram.lua
-- A simple script to monitor a Mekanism Fission Reactor and SCRAM it if the temperature exceeds a set threshold.

-- Configuration
local TEMP_THRESHOLD = 1200 -- Temperature in Kelvin. Mekanism's 'High Temperature' threshold is 1200K[reference:8].
local REACTOR_SIDE = "left"  -- The side of the computer the reactor logic adapter is on. Change this as needed.
local CHECK_INTERVAL = 1     -- How often to check the temperature, in seconds.

-- Find the reactor peripheral
local reactor = peripheral.find("fissionReactorLogicAdapter")

if reactor == nil then
    print("ERROR: Could not find a Fission Reactor Logic Adapter.")
    print("Make sure it is connected to your computer and is on the network.")
    return
end

print("Reactor SCRAM monitor started.")
print("Monitoring temperature on side: " .. REACTOR_SIDE)
print("SCRAM threshold set to: " .. TEMP_THRESHOLD .. "K")
print("Press Ctrl + T to stop the script.")

-- Main monitoring loop
while true do
    -- Get the reactor's current temperature
    -- Note: The exact method to get temperature might vary.
    -- This example assumes the reactor peripheral has a getTemperature() function.
    -- You may need to adapt this based on your specific peripherals (e.g., using a Fission Reactor Logic Adapter).
    local temperature = reactor.getTemperature()

    if temperature == nil then
        print("WARNING: Could not read temperature. Is the reactor formed?")
    elseif temperature > TEMP_THRESHOLD then
        print("WARNING: Temperature (" .. temperature .. "K) exceeded threshold (" .. TEMP_THRESHOLD .. "K)! SCRAMMING REACTOR!")
        -- SCRAM the reactor. The scram() function deactivates the reactor[reference:9].
        reactor.scram()
        print("Reactor has been SCRAMMED.")
        -- Optional: Add a redstone signal or other alert here.
        -- The script stops after a SCRAM to prevent it from immediately re-enabling the reactor.
        break
    else
        -- Print status every few checks to show it's working
        -- print("Temperature: " .. temperature .. "K (Safe)")
    end

    sleep(CHECK_INTERVAL)
end

print("Reactor monitor stopped.")
