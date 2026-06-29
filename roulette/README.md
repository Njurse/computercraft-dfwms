# Buckshot Roulette — ComputerCraft Edition
## Create + Mekanism | CC:Tweaked

A polished, multiplayer Buckshot Roulette-inspired minigame built entirely in ComputerCraft: Tweaked.
Physical shell loading, drill targeting, and motor control are handled by Create and Mekanism hardware.

---

## File Layout

```
buckshot_roulette/
├── admin.lua              → RouletteAdmin main script
├── player.lua             → Roulette1 & Roulette2 (shared script, auto-detects label)
├── motor_ctrl.lua         → RouletteMotorCtrl
├── lib/
│   ├── network.lua        → Rednet helpers, packet types, discovery
│   ├── game_state.lua     → Shell types, health, magazine generation, turn logic
│   ├── ui.lua             → Color-aware monitor rendering primitives
│   ├── inventory.lua      → Hardware-agnostic inventory & logistics abstraction
│   └── center_display.lua → Center Advanced Monitor rendering
└── startup/
    ├── RouletteAdmin_startup.lua
    ├── Roulette1_startup.lua
    ├── Roulette2_startup.lua
    └── RouletteMotorCtrl_startup.lua
```

All four computers need the full `lib/` folder copied to them.

---

## Computer Summary

| Label              | Type     | Monitor          | Key Peripherals                          |
|--------------------|----------|------------------|------------------------------------------|
| RouletteAdmin      | Advanced | Advanced (large) | Wired modem, inventories (3), detectors  |
| Roulette1          | Advanced | Advanced (3-wide)| Wired modem                              |
| Roulette2          | Advanced | Advanced (3-wide)| Wired modem                              |
| RouletteMotorCtrl  | Normal   | None             | Wired modem, Electric Motor, Seq Gearbox |

---

## Installation

### 1. Copy files to each computer

Every computer needs:
```
lib/network.lua
lib/game_state.lua
lib/ui.lua
lib/inventory.lua
lib/center_display.lua
```

Then each computer gets its own main script:

| Computer           | Main script    | Startup file                    |
|--------------------|----------------|---------------------------------|
| RouletteAdmin      | admin.lua      | RouletteAdmin_startup.lua       |
| Roulette1          | player.lua     | Roulette1_startup.lua           |
| Roulette2          | player.lua     | Roulette2_startup.lua           |
| RouletteMotorCtrl  | motor_ctrl.lua | RouletteMotorCtrl_startup.lua   |

Rename the correct startup file to `startup.lua` on each computer.

### 2. Set computer labels

The startup scripts set labels automatically on first boot and reboot.
You can also set them manually:
```lua
> os.setComputerLabel("RouletteAdmin")
```

### 3. Connect wired modems

- Attach a **Wired Modem** to each computer (any side).
- Right-click the modem to activate it.
- Connect all four computers with **Networking Cable**.
- All computers must be on the same cable network.

### 4. Attach monitors

**RouletteAdmin:** Place an Advanced Monitor (at least 2×2 blocks, larger is better)
adjacent to the computer or connected via the same cable. The script finds the largest
color monitor automatically.

**Roulette1 & Roulette2:** Place an Advanced Monitor exactly **3 blocks wide** (and any
height, 2–3 tall is ideal) adjacent to the computer or connected via cable.

### 5. Attach inventories (RouletteAdmin)

Connect **three inventory blocks** (chests, barrels, or Create Depots) via cable or
directly adjacent. The script assigns them by slot count:

| Inventory size | Role      | Purpose                          |
|----------------|-----------|----------------------------------|
| Largest        | STORAGE   | Stock of Infused Alloy + Reinforced Alloy |
| Medium         | MAGAZINE  | Shells loaded for the current round |
| Smallest/single| CHAMBER   | Single-slot drawer — shows the currently chambered shell |

Fill STORAGE with:
- `mekanism:infused_alloy`    (Live rounds)
- `mekanism:reinforced_alloy` (Blank rounds)

### 6. Attach motor hardware (RouletteMotorCtrl)

Connect via cable (or directly adjacent):
- **Create Electric Motor**
- **Create Sequential Gearbox** (attached below the drill)

The script auto-discovers both via peripheral type scanning.

---

## Startup Order

Start in any order — each computer retries discovery until all peers are found.
Recommended order for clean startup:

1. RouletteMotorCtrl
2. Roulette1
3. Roulette2
4. RouletteAdmin

---

## Debug Mode

In `admin.lua`, at the top:

```lua
local DEBUG_SINGLE_PLAYER = false
```

Set to `true` to allow one player to start the game alone (useful for testing without
both player stations online).

---

## Game Flow

```
Both players press READY on their monitors
           ↓
Admin generates magazine (e.g. 3 Live, 2 Blank)
           ↓
Center display: "3 BLANK  2 LIVE"
           ↓
Center display: "I INSERT THE ROUNDS IN A RANDOM ORDER."
           ↓
Items physically moved from STORAGE → MAGAZINE inventory
           ↓
Game begins — Player 1 goes first
           ↓
Active player sees: YOUR TURN / Shoot Yourself / Shoot Opponent
           ↓
Player selects action (keyboard ↑↓ Enter, or monitor tap)
           ↓
Admin tells MotorCtrl to aim (P1 = left, P2 = right)
           ↓
MotorCtrl rotates gearbox, starts drill, stops drill
           ↓
Shell result revealed on center display
           ↓
• Live Round → target loses 1 heart; turn passes
• Blank at opponent → turn passes
• Blank at self → BONUS TURN (player goes again)
           ↓
Repeat until a player reaches 0 hearts
           ↓
Winner screen on center + both player monitors
           ↓
Auto-restart to lobby after 8 seconds
```

---

## Networking Protocol

All messages are serialized Lua tables on the `"roulette"` Rednet protocol.

```lua
{
    type      = "PKT_TYPE_CONSTANT",
    sender    = "hostname",
    recipient = recipientId,
    payload   = { ... },
}
```

### Packet Types

| Packet          | From            | To              | Purpose                            |
|-----------------|-----------------|-----------------|------------------------------------|
| WHO_ARE_YOU     | Any             | Broadcast       | Discovery probe                    |
| I_AM            | Any             | Requester       | Discovery reply                    |
| READY           | Player          | Admin           | Player pressed ready               |
| START_GAME      | Admin           | Players         | Game is beginning                  |
| YOUR_TURN       | Admin           | Active player   | It is your turn                    |
| WAITING         | Admin           | Inactive player | Wait for opponent                  |
| PLAYER_ACTION   | Player          | Admin           | "self" or "opponent"               |
| TURN_RESULT     | Admin           | Both players    | Shell revealed, damage, next turn  |
| HEALTH_UPDATE   | Admin           | Both players    | Current HP values                  |
| SHOW_MESSAGE    | Admin           | Both players    | Narrative/status text              |
| GAME_OVER       | Admin           | Both players    | Winner announced                   |
| AIM             | Admin           | MotorCtrl       | Rotate drill toward target         |
| FIRE            | Admin           | MotorCtrl       | Start and stop drill               |
| MOTOR_DONE      | MotorCtrl       | Admin           | Hardware action complete           |
| PING / PONG     | Any             | Any             | Latency check / alive check        |

---

## Adding New Shell Types

1. Add a key to `GS.SHELL` in `lib/game_state.lua`:
   ```lua
   GameState.SHELL.DOUBLE = "DOUBLE"
   ```

2. Map it to a Minecraft item in `GS.SHELL_ITEMS`:
   ```lua
   [GameState.SHELL.DOUBLE] = "mekanism:atomic_alloy"
   ```

3. Add a display name to `GS.SHELL_NAMES`.

4. Handle the new type in `GameState.applyShot()`:
   ```lua
   elseif shell == GameState.SHELL.DOUBLE then
       result.damage = 2
       -- ...
   ```

5. In `admin.lua`, pass `DOUBLE_DAMAGE_RPM` to `fire()` when this shell is active.

---

## Fault Tolerance

| Failure                       | Behavior                                              |
|-------------------------------|-------------------------------------------------------|
| Missing modem                 | Errors clearly, halts with message                   |
| Missing monitor               | Game runs headless (terminal only)                   |
| Missing inventories           | Software-only mode; items not physically moved       |
| Missing motor / gearbox       | Drill commands logged but not executed               |
| Peer computer offline         | Discovery retries every 3 seconds indefinitely       |
| Network timeout (action)      | Admin re-sends YOUR_TURN after 30s                   |
| Motor controller timeout      | Warning logged, game continues                       |
| Any script crash (pcall)      | Automatic restart after 5 seconds                   |

---

## Motor Controller — Gearbox API Compatibility

`motor_ctrl.lua` tries three API patterns when rotating the gearbox:

1. `gearbox.rotate(steps, direction)` — Create 0.5.1+
2. `gearbox.stepForward(steps)` / `gearbox.stepBackward(steps)`
3. `gearbox.setAngle(degrees)`

If none match your version, add a fourth pattern in the `rotateGearbox()` function
in `motor_ctrl.lua`.

---

## Item IDs (Edit to Match Your Pack)

In `lib/game_state.lua`:

```lua
GameState.SHELL_ITEMS = {
    [GameState.SHELL.LIVE]  = "mekanism:infused_alloy",
    [GameState.SHELL.BLANK] = "mekanism:reinforced_alloy",
}
```

Replace these with the exact IDs from your modpack if they differ.
Use the `/give` command or an item viewer mod (JEI, REI) to confirm IDs.
