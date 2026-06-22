```lua
local ui = {}

ui.color = term.isColor()

function ui.setText(color)
    if ui.color then
        term.setTextColor(color)
    end
end

function ui.setBackground(color)
    if ui.color then
        term.setBackgroundColor(color)
    end
end

function ui.reset()
    if ui.color then
        term.setTextColor(colors.white)
        term.setBackgroundColor(colors.black)
    end
end

function ui.clear()
    term.clear()
    term.setCursorPos(1, 1)
end

function ui.draw(state)
    ui.clear()

    ui.setText(colors.cyan)
    print("=== DFPWM JUKEBOX ===")
    ui.reset()

    print("")
    print("ENTER = Play")
    print("S     = Stop")
    print("Q     = Quit")
    print("")

    for i, song in ipairs(state.songs) do
        if i == state.selected then
            ui.setText(colors.lime)
            write("> ")
        else
            write("  ")
        end

        print(song)
        ui.reset()
    end

    print("")

    if state.playing then
        ui.setText(colors.green)
        print("Playing: " .. (state.currentSong or ""))
    else
        ui.setText(colors.lightGray)
        print("Stopped")
    end

    ui.reset()
end

return ui
```
