-- Optimized Cylinder Builder for ComputerCraft Turtle
-- Uses a simpler circle-building algorithm

function checkFuel()
    local currentFuel = turtle.getFuelLevel()
    if currentFuel == "unlimited" then
        return true
    end
    
    print("Current fuel: " .. currentFuel)
    if currentFuel < 100 then
        print("Warning: Low fuel! Please refuel.")
        return false
    end
    return true
end

function getPositiveInput(prompt)
    local input
    repeat
        write(prompt)
        input = tonumber(read())
        if not input or input <= 0 or math.floor(input) ~= input then
            print("Please enter a positive integer.")
            input = nil
        end
    until input ~= nil
    return input
end

function buildCircleLayer(radius)
    -- Place block at center
    turtle.placeDown()
    
    -- Build concentric squares that approximate a circle
    for layer = 0, radius do
        local diameter = 2 * layer + 1
        local halfSize = layer
        
        -- Move to the top-right corner of the square
        turtle.turnRight()
        for i = 1, halfSize do turtle.forward() end
        turtle.turnLeft()
        for i = 1, halfSize do turtle.forward() end
        
        -- Draw the square ring
        -- Right side
        turtle.turnRight()
        for i = 1, diameter - 1 do
            turtle.forward()
            if math.sqrt((i - halfSize)^2 + (layer)^2) <= radius + 0.5 then
                turtle.placeDown()
            end
        end
        
        -- Bottom side
        turtle.turnRight()
        for i = 1, diameter - 1 do
            turtle.forward()
            if math.sqrt((layer)^2 + (i - halfSize)^2) <= radius + 0.5 then
                turtle.placeDown()
            end
        end
        
        -- Left side
        turtle.turnRight()
        for i = 1, diameter - 1 do
            turtle.forward()
            if math.sqrt((i - halfSize)^2 + (layer)^2) <= radius + 0.5 then
                turtle.placeDown()
            end
        end
        
        -- Top side
        turtle.turnRight()
        for i = 1, diameter - 2 do
            turtle.forward()
            if math.sqrt((layer)^2 + (i - halfSize)^2) <= radius + 0.5 then
                turtle.placeDown()
            end
        end
        
        -- Return to center
        turtle.turnRight()
        for i = 1, halfSize do turtle.forward() end
        turtle.turnRight()
        for i = 1, halfSize do turtle.forward() end
        turtle.turnRight()
    end
end

function buildCylinder()
    print("=== Cylinder Builder ===")
    print()
    
    if not checkFuel() then
        print("Please refuel and try again.")
        return
    end
    
    local radius = getPositiveInput("Enter radius (in blocks): ")
    local height = getPositiveInput("Enter height (in blocks): ")
    
    print()
    print("Building cylinder with radius " .. radius .. " and height " .. height)
    
    local totalBlocks = math.floor(math.pi * radius * radius * height)
    print("Estimated blocks needed: ~" .. totalBlocks)
    print()
    
    write("Continue? (y/n): ")
    local confirm = read()
    if confirm:lower() ~= "y" then
        print("Build cancelled.")
        return
    end
    
    print("Starting build...")
    
    for layer = 1, height do
        print("Layer " .. layer .. "/" .. height)
        buildCircleLayer(radius)
        if layer < height then
            turtle.up()
        end
    end
    
    print()
    print("Cylinder construction complete!")
    print("Returning to starting position...")
    
    -- Return to original position
    for i = 1, height - 1 do
        turtle.down()
    end
end

-- Run the program
buildCylinder()
