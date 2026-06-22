```lua
local ui = require("ui")
local player = require("player")

local state = {
    songs = {},
    selected = 1,
    playing = false,
    currentSong = nil
}

local function loadSongs()
    state.songs = {}

    if not fs.exists("music") then
        fs.makeDir("music")
    end

    for _, file in ipairs(fs.list("music")) do
        if file:lower():match("%.dfpwm$") then
            table.insert(state.songs, file)
        end
    end

    table.sort(state.songs)
end

loadSongs()

if #state.songs == 0 then
    print("No DFPWM files found in music/")
    return
end

local function playbackThread()
    while true do
        sleep(0.1)

        state.playing = player.playing
    end
end

local function uiThread()
    while true do
        ui.draw(state)

        local _, key = os.pullEvent("key")

        if key == keys.up then
            state.selected = math.max(1, state.selected - 1)

        elseif key == keys.down then
            state.selected = math.min(#state.songs, state.selected + 1)

        elseif key == keys.enter then
            player.stop()

            sleep(0.1)

            local song = state.songs[state.selected]

            state.currentSong = song

            local path = fs.combine("music", song)

            state.playing = true

            local playPath = path

            parallel.waitForAny(
                function()
                    player.play(playPath)
                    state.playing = false
                end,

                function()
                    while player.playing do
                        sleep(0.1)
                    end
                end
            )

        elseif key == keys.s then
            player.stop()
            state.playing = false

        elseif key == keys.q then
            player.stop()
            term.clear()
            term.setCursorPos(1,1)
            return
        end
    end
end

parallel.waitForAny(
    uiThread,
    playbackThread
)
```
