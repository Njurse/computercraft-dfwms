-- lib/ui.lua
-- Monitor rendering helpers.
-- Works with both Advanced Monitors (color) and Standard Monitors (greyscale/text).
-- Callers pass a `mon` peripheral handle; the module adapts automatically.

local UI = {}

-- ── Color palette (falls back to white/black if no color support) ──────────
UI.COLOR = {
    BACKGROUND  = colors.black,
    TEXT        = colors.white,
    HIGHLIGHT   = colors.yellow,
    LIVE_SHELL  = colors.red,
    BLANK_SHELL = colors.lightBlue,
    HEALTH_FULL = colors.red,
    HEALTH_EMPTY= colors.gray,
    HEADER      = colors.orange,
    WINNER      = colors.yellow,
    DIM         = colors.gray,
    SUCCESS     = colors.lime,
    WARNING     = colors.orange,
    ERROR       = colors.red,
}

-- Heart symbols
UI.HEART_FULL  = "\3"   -- CC heart glyph (♥)
UI.HEART_EMPTY = "\7"   -- CC bullet (·) used as empty heart

-- ── Internal helpers ───────────────────────────────────────────────────────

local function isColor(mon)
    return mon and mon.isColor and mon.isColor()
end

local function safeSetBg(mon, col)
    if isColor(mon) then
        mon.setBackgroundColor(col)
    else
        mon.setBackgroundColor(colors.black)
    end
end

local function safeSetFg(mon, col)
    if isColor(mon) then
        mon.setTextColor(col)
    else
        mon.setTextColor(colors.white)
    end
end

-- ── Public API ─────────────────────────────────────────────────────────────

--- Clear the monitor and reset colors.
---@param mon table
function UI.clear(mon)
    safeSetBg(mon, UI.COLOR.BACKGROUND)
    safeSetFg(mon, UI.COLOR.TEXT)
    mon.clear()
    mon.setCursorPos(1, 1)
end

--- Write text at (x, y) with optional foreground color.
---@param mon  table
---@param x    number
---@param y    number
---@param text string
---@param fg   number|nil  colors.*
---@param bg   number|nil  colors.*
function UI.write(mon, x, y, text, fg, bg)
    mon.setCursorPos(x, y)
    safeSetBg(mon, bg or UI.COLOR.BACKGROUND)
    safeSetFg(mon, fg or UI.COLOR.TEXT)
    mon.write(text)
end

--- Write text centered horizontally on a given row.
---@param mon   table
---@param y     number
---@param text  string
---@param fg    number|nil
---@param bg    number|nil
function UI.writeCentered(mon, y, text, fg, bg)
    local w, _ = mon.getSize()
    local x = math.max(1, math.floor((w - #text) / 2) + 1)
    UI.write(mon, x, y, text, fg, bg)
end

--- Draw a horizontal rule across a row.
---@param mon  table
---@param y    number
---@param char string|nil  (default "─")
---@param fg   number|nil
function UI.hRule(mon, y, char, fg)
    char = char or "\140"  -- CC box-drawing horizontal
    local w, _ = mon.getSize()
    UI.write(mon, 1, y, string.rep(char, w), fg or UI.COLOR.DIM)
end

--- Fill an entire row with a background color.
---@param mon  table
---@param y    number
---@param bg   number
function UI.fillRow(mon, y, bg)
    local w, _ = mon.getSize()
    safeSetBg(mon, bg)
    safeSetFg(mon, UI.COLOR.TEXT)
    mon.setCursorPos(1, y)
    mon.write(string.rep(" ", w))
end

--- Render a health bar as heart symbols.
--- Returns the rendered string (also prints to mon if provided).
---@param mon     table|nil
---@param x       number
---@param y       number
---@param current number
---@param max     number
---@return string
function UI.healthBar(mon, x, y, current, max)
    local bar = ""
    for i = 1, max do
        bar = bar .. (i <= current and UI.HEART_FULL or UI.HEART_EMPTY)
    end
    if mon then
        -- Render heart-by-heart with color
        mon.setCursorPos(x, y)
        for i = 1, max do
            local filled = (i <= current)
            safeSetBg(mon, UI.COLOR.BACKGROUND)
            safeSetFg(mon, filled and UI.COLOR.HEALTH_FULL or UI.COLOR.HEALTH_EMPTY)
            mon.write(filled and UI.HEART_FULL or UI.HEART_EMPTY)
        end
    end
    return bar
end

--- Draw a simple bordered box (single-line ASCII).
---@param mon  table
---@param x1   number
---@param y1   number
---@param x2   number
---@param y2   number
---@param fg   number|nil
function UI.box(mon, x1, y1, x2, y2, fg)
    fg = fg or UI.COLOR.DIM
    local w = x2 - x1 + 1
    -- Top / bottom borders
    UI.write(mon, x1, y1, "+" .. string.rep("-", w - 2) .. "+", fg)
    UI.write(mon, x1, y2, "+" .. string.rep("-", w - 2) .. "+", fg)
    -- Side borders
    for row = y1 + 1, y2 - 1 do
        UI.write(mon, x1, row, "|", fg)
        UI.write(mon, x2, row, "|", fg)
    end
end

--- Print a scrolling-style message with a brief pause.
--- Useful for narrative display sequences on the center monitor.
---@param mon   table
---@param y     number   row to print on
---@param text  string
---@param delay number   seconds to pause after printing (default 0)
---@param fg    number|nil
function UI.narrative(mon, y, text, delay, fg)
    UI.clear(mon)
    UI.writeCentered(mon, y, text, fg or UI.COLOR.TEXT)
    if delay and delay > 0 then
        sleep(delay)
    end
end

--- Render a menu with one highlighted option.
--- items: list of strings
--- selected: 1-based index of highlighted item
---@param mon      table
---@param startY   number
---@param items    table
---@param selected number
function UI.menu(mon, startY, items, selected)
    local w, _ = mon.getSize()
    for i, item in ipairs(items) do
        local y   = startY + (i - 1)
        local row = " " .. item .. string.rep(" ", w - #item - 1)
        if i == selected then
            UI.fillRow(mon, y, UI.COLOR.HIGHLIGHT)
            safeSetFg(mon, colors.black)
            safeSetBg(mon, UI.COLOR.HIGHLIGHT)
            mon.setCursorPos(1, y)
            mon.write(row)
        else
            UI.fillRow(mon, y, UI.COLOR.BACKGROUND)
            safeSetFg(mon, UI.COLOR.TEXT)
            safeSetBg(mon, UI.COLOR.BACKGROUND)
            mon.setCursorPos(1, y)
            mon.write(row)
        end
    end
end

--- Display a full-screen error message.
---@param mon  table
---@param msg  string
function UI.error(mon, msg)
    UI.clear(mon)
    local _, h = mon.getSize()
    local mid  = math.floor(h / 2)
    UI.writeCentered(mon, mid - 1, "!! ERROR !!", UI.COLOR.ERROR)
    UI.writeCentered(mon, mid + 1, msg,            UI.COLOR.WARNING)
end

--- Display a full-screen "waiting" message.
---@param mon  table
---@param msg  string|nil
function UI.waiting(mon, msg)
    UI.clear(mon)
    local _, h = mon.getSize()
    local mid  = math.floor(h / 2)
    UI.writeCentered(mon, mid, msg or "WAITING...", UI.COLOR.DIM)
end

return UI
