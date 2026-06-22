```lua
local player = {}

local dfpwm = require("cc.audio.dfpwm")

local speaker = peripheral.find("speaker")

if not speaker then
    error("No speaker attached")
end

player.stopRequested = false
player.playing = false

function player.stop()
    player.stopRequested = true
    speaker.stop()
end

function player.play(path)
    player.stopRequested = false
    player.playing = true

    local decoder = dfpwm.make_decoder()

    for chunk in io.lines(path, 16 * 1024) do
        if player.stopRequested then
            break
        end

        local buffer = decoder(chunk)

        while not speaker.playAudio(buffer) do
            local event = { os.pullEvent() }

            if player.stopRequested then
                break
            end

            if event[1] ~= "speaker_audio_empty" then
                os.queueEvent(table.unpack(event))
            end
        end
    end

    player.playing = false
end

return player
```
