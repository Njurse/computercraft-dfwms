-- Cylinder Builder for ComputerCraft Turtle
-- Prompts user for radius and height, then builds a cylinder

-- Function to check if turtle has enough fuel
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

-- Function to get valid positive integer input
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

-- Function to build a single layer (circle) of the cylinder
function buildCircle(radius, isBase)
    -- Position turtle at start of circle (relative to center)
    -- Move to starting position: radius + 1 blocks to the right
    for i = 1, radius + 1 do
        turtle.forward()
    end
    
    -- Place block at starting position if this is the base
    if isBase then
        turtle.placeDown()
    end
    
    -- Build the circle using Bresenham's circle algorithm
    local x = radius
    local y = 0
    local decision = 1 - radius
    
    while x >= y do
        -- Place blocks in all 8 octants
        local positions = {
            {x, y}, {y, x}, {-y, x}, {-x, y},
            {-x, -y}, {-y, -x}, {y, -x}, {x, -y}
        }
        
        for _, pos in ipairs(positions) do
            local dx, dy = pos[1], pos[2]
            
            -- Move to the correct position relative to center
            -- This is a simplified approach - navigate to each position
            
            -- Calculate direction and distance to move
            local targetX = dx
            local targetY = dy
            
            -- Move to target position (simplified for this example)
            -- In a real implementation, you'd need pathfinding
            -- For now, we'll use a simpler method
            
            -- Return to center
            for i = 1, radius + 1 do
                turtle.back()
            end
            
            -- Move to new position
            if targetX > 0 then
                for i = 1, targetX do turtle.forward() end
            elseif targetX < 0 then
                for i = 1, -targetX do turtle.back() end
            end
            
            if targetY > 0 then
                for i = 1, targetY do turtle.turnRight() turtle.forward() turtle.turnLeft() end
            elseif targetY < 0 then
                for i = 1, -targetY do turtle.turnLeft() turtle.forward() turtle.turnRight() end
            end
            
            -- Place block if this is the base layer
            if isBase then
                turtle.placeDown()
            end
        end
        
        y = y + 1
        if decision < 0 then
            decision = decision + 2 * y + 1
        else
            x = x - 1
            decision = decision + 2 * (y - x) + 1
        end
    end
end

-- Main function to build the cylinder
function buildCylinder()
    print("=== Cylinder Builder ===")
    print()
    
    -- Check fuel
    if not checkFuel() then
        print("Please refuel and try again.")
        return
    end
    
    -- Get radius and height
    local radius = getPositiveInput("Enter radius (in blocks): ")
    local height = getPositiveInput("Enter height (in blocks): ")
    
    print()
    print("Building cylinder with radius " .. radius .. " and height " .. height)
    print("Please ensure the turtle has enough materials!")
    print("Estimated blocks needed: ~" .. math.floor(math.pi * radius * radius * height))
    print()
    
    write("Continue? (y/n): ")
    local confirm = read()
    if confirm:lower() ~= "y" then
        print("Build cancelled.")
        return
    end
    
    -- Build the cylinder layer by layer
    local totalLayers = height
    for layer = 1, totalLayers do
        print("Building layer " .. layer .. " of " .. totalLayers)
        
        -- Build this layer
        buildCircle(radius, true)
        
        -- Move up for next layer
        if layer < totalLayers then
            turtle.up()
        end
    end
    
    print()
    print("Cylinder construction complete!")
end

-- Run the program
buildCylinder()
