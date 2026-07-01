# CC Schematic Builder — Setup Guide

A wireless schematic-building system for ComputerCraft/CC:Tweaked consisting
of two scripts: a **pocket computer client** and a **turtle server**.

---

## Files

| File | Goes on |
|---|---|
| `pocket_client.lua` | Your Pocket Computer |
| `turtle_server.lua` | The building Turtle |
| `example_cabin.lua` | Any disk/filesystem accessible to the client |

---

## Requirements

- **CC:Tweaked** (or ComputerCraft with Advanced Turtles)
- A **GPS constellation** (4 computers with `gps host`) — required for automatic
  facing detection and origin alignment
- The **Turtle** must have a wireless modem attached (any side)
- The **Pocket Computer** must have the **Wireless Modem** upgrade equipped
- The turtle needs enough fuel and the right blocks in its inventory

---

## Quick Start

### 1 — Install the scripts

Paste or transfer the files. Using a disk drive or `wget` (if HTTP is enabled):
```
wget https://.../turtle_server.lua  (on turtle)
wget https://.../pocket_client.lua  (on pocket computer)
```

Or use `pastebin get <code> turtle_server` if you've uploaded them.

### 2 — Start the turtle server
```lua
turtle_server
```
The turtle will open its listening channel (7778) and print its GPS fix.

### 3 — Start the pocket client
```lua
pocket_client
```

### 4 — Discover the turtle
Press `[D]` on the home screen. The client broadcasts on channel 7777 and waits
up to 4 seconds for turtle announcements. Select the turtle you want to use.

### 5 — Load a schematic
Press `[S]`. Choose a built-in test schematic, or `[Load from file]` and enter
the path to your `.lua` schematic (e.g. `/disk/example_cabin.lua`).

### 6 — Align the turtle
This is the most important step. Press `[A]` on the home screen.

- **Position the turtle** at your desired build origin (bottom-left-front corner
  of the structure, from the perspective of the direction it will face).
- Use `[L]`/`[R]` to set which direction the turtle will face during the build.
- Press `[G]` to use the turtle's current GPS position as origin (recommended),
  or `[M]` to enter world coordinates manually.
- Press `[A]` to send the align command.

**What happens during alignment:**
1. The turtle receives the target facing and origin coordinates.
2. It steps forward one block and takes two GPS readings to detect its *actual*
   facing (GPS gives position only, not rotation).
3. It steps back and rotates to match the requested facing.
4. It sends back an ACK with the detected facing and confirmed GPS position.

> ⚠️  Make sure there is a free block in front of the turtle when aligning —
> it needs to take one step to detect facing.

### 7 — Start the build
Press `[B]`. Review the summary and press `[Y]` to confirm.

The client will:
1. Rotate the schematic to match the chosen facing.
2. Stream the full block list to the turtle.
3. Display a live progress bar as the turtle builds.

---

## Channels

| Channel | Purpose |
|---|---|
| `7777` | Client → Turtle (discover, commands) |
| `7778` | Turtle → Client (replies, progress) |

Change both `CHANNEL` and `CHANNEL_RX` at the top of both scripts if needed,
but they must be swapped between the two files.

---

## Schematic Format

Schematics are plain Lua files that return a table:

```lua
return {
  name   = "My Structure",
  blocks = {
    {rx=0, ry=0, rz=0, block="minecraft:stone"},
    {rx=1, ry=0, rz=0, block="minecraft:oak_planks"},
    -- ...
  }
}
```

Coordinates are **relative to the turtle's origin**, with the turtle facing `+Z`
(i.e. `rz` grows in the direction the turtle faces). The client automatically
rotates the schematic if you choose a different facing.

| Axis | Direction |
|---|---|
| `rx` positive | right of turtle |
| `rx` negative | left of turtle |
| `ry` positive | up |
| `rz` positive | in front of turtle (forward) |
| `rz` negative | behind turtle |

---

## Building Strategy

- Blocks are sorted **bottom layer first**, then by X then Z (row by row).
- The turtle navigates to one block **above** each target position and uses
  `turtle.placeDown()`.
- It goes **up first** before moving horizontally to avoid running into walls.
- After the build it returns to the origin `(0,0,0)`.
- If a required block isn't in inventory, it logs the missing block and
  continues to the next one.

---

## Turtle Inventory

Arrange blocks in the turtle's 16 inventory slots. The turtle searches all
slots for the right item name (e.g. `minecraft:stone`). If you run out of a
block mid-build, the turtle will skip those positions and log them.

---

## Tips

- **Fuel:** Check fuel with `[T]` (Status screen). Stone gives 1 fuel/block —
  a large build may need coal or lava.
- **Multiple turtles:** Each turtle runs its own server. Discover and select
  them one at a time. The client handles one turtle at a time.
- **Large schematics:** The entire block list is sent in one modem message.
  Very large schematics (1000+ blocks) should work but may cause a brief
  pause while transmitting.
- **Alignment is everything:** If the build looks offset or rotated, re-align
  and rebuild. Use `[T]` to check the turtle's confirmed GPS position and facing.
