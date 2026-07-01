#!/usr/bin/env python3
"""
convert_schematic.py  —  Convert Minecraft schematics to CC Builder Lua format
Supports:
  • .litematic  (Litematica mod, any modern version)
  • .schem       (WorldEdit / Sponge format, 1.13+)
  • .schematic   (MCEdit / legacy WorldEdit, pre-1.13, numeric block IDs)

Output: a .lua file loadable by pocket_client.lua

Usage:
    python3 convert_schematic.py input.litematic [output.lua]
    python3 convert_schematic.py input.schem [output.lua]
    python3 convert_schematic.py input.schematic [output.lua]

Options:
    --no-air        Skip air blocks (default: air is always skipped)
    --filter BLOCK  Only include blocks matching this string (e.g. "stone")
    --origin X,Y,Z  Shift the entire schematic so this world-coord is (0,0,0)
    --stats         Print a block count summary after conversion
"""

import sys
import os
import math
import gzip
import struct
import argparse
from io import BytesIO

try:
    import nbtlib
except ImportError:
    sys.exit("ERROR: nbtlib not installed. Run:  pip install nbtlib")


# ── Helpers ───────────────────────────────────────────────────────────────────

def err(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg):
    print(f"  {msg}")


# ── Litematic bit-packing decoder ─────────────────────────────────────────────
# Litematica uses a bit-packed long array (pre-1.16 style used by the mod):
#   bits_per_entry = max(2, ceil(log2(palette_size)))
#   entries span across long boundaries (no padding per long)
#   index formula: block_index = x + z * width + y * width * length

def decode_litematic_blockstates(long_array, palette_size, volume):
    """Decode Litematica's bit-packed BlockStates long array."""
    bits = max(2, math.ceil(math.log2(palette_size))) if palette_size > 1 else 1
    mask = (1 << bits) - 1

    # Concatenate all longs into one big integer (big-endian within each long,
    # but longs are stored little-endian in the array index sense)
    # Each long is a signed 64-bit int; we need the raw bits as unsigned.
    result = []
    bit_buf = 0
    buf_bits = 0
    long_idx = 0

    for i in range(volume):
        while buf_bits < bits:
            if long_idx < len(long_array):
                val = int(long_array[long_idx]) & 0xFFFFFFFFFFFFFFFF  # to unsigned
                bit_buf |= val << buf_bits
                buf_bits += 64
                long_idx += 1
            else:
                break
        result.append(bit_buf & mask)
        bit_buf >>= bits
        buf_bits -= bits

    return result


# ── .litematic parser ─────────────────────────────────────────────────────────

def parse_litematic(nbt):
    """
    Returns list of (x, y, z, block_name) tuples.
    Multi-region schematics: all regions are merged with their relative offsets.
    """
    blocks = []

    regions = nbt.get("Regions", {})
    if not regions:
        err("No Regions found in .litematic file")

    for region_name, region in regions.items():
        info(f"Region: '{region_name}'")

        size = region["Size"]
        sx = int(size["x"])
        sy = int(size["y"])
        sz = int(size["z"])

        # Dimensions can be negative (region direction)
        width  = abs(sx)
        height = abs(sy)
        length = abs(sz)
        volume = width * height * length

        pos = region.get("Position", None)
        ox = int(pos["x"]) if pos else 0
        oy = int(pos["y"]) if pos else 0
        oz = int(pos["z"]) if pos else 0

        palette = region["BlockStatePalette"]
        palette_names = []
        for entry in palette:
            name = str(entry["Name"])
            palette_names.append(name)

        info(f"  Size: {width}x{height}x{length}  Palette: {len(palette_names)} blocks")

        long_array = region["BlockStates"]
        indices = decode_litematic_blockstates(long_array, len(palette_names), volume)

        # Litematica index: i = x + z * width + y * width * length
        for y in range(height):
            for z in range(length):
                for x in range(width):
                    idx = x + z * width + y * width * length
                    if idx >= len(indices):
                        continue
                    palette_idx = indices[idx]
                    if palette_idx >= len(palette_names):
                        continue
                    name = palette_names[palette_idx]
                    if "air" in name:
                        continue
                    # Apply region direction (negative size = inverted axis)
                    rx = x if sx >= 0 else (width  - 1 - x)
                    ry = y if sy >= 0 else (height - 1 - y)
                    rz = z if sz >= 0 else (length - 1 - z)
                    blocks.append((ox + rx, oy + ry, oz + rz, name))

    return blocks


# ── .schem (Sponge) parser ────────────────────────────────────────────────────
# Sponge format uses a palette map (block_name → palette_int) and a
# varint-encoded BlockData byte array.

def decode_varint_array(data, count):
    """Decode a varint-encoded byte array into a list of ints."""
    result = []
    i = 0
    while len(result) < count and i < len(data):
        val = 0
        shift = 0
        while True:
            b = data[i] if isinstance(data[i], int) else ord(data[i])
            i += 1
            val |= (b & 0x7F) << shift
            shift += 7
            if not (b & 0x80):
                break
        result.append(val)
    return result


def parse_schem(nbt):
    """Parse WorldEdit .schem (Sponge) format."""
    blocks = []

    width  = int(nbt["Width"])
    height = int(nbt["Height"])
    length = int(nbt["Length"])

    info(f"Size: {width}x{height}x{length}")

    # Palette is a Compound mapping name -> Int (palette index)
    palette = nbt["Palette"]
    # Invert: index -> name
    palette_inv = {}
    for name, idx in palette.items():
        palette_inv[int(idx)] = name

    info(f"Palette: {len(palette_inv)} blocks")

    # BlockData is a byte array of varints
    block_data_raw = bytes(nbt["BlockData"])
    volume = width * height * length
    indices = decode_varint_array(block_data_raw, volume)

    # Sponge index: i = y * width * length + z * width + x
    for y in range(height):
        for z in range(length):
            for x in range(width):
                i = y * width * length + z * width + x
                if i >= len(indices):
                    continue
                name = palette_inv.get(indices[i], "minecraft:air")
                if "air" in name:
                    continue
                blocks.append((x, y, z, name))

    return blocks


# ── .schematic (MCEdit legacy) parser ─────────────────────────────────────────
# Legacy format uses numeric block IDs in a byte array.
# We do a best-effort mapping for common block IDs.

LEGACY_BLOCK_MAP = {
    1:  "minecraft:stone",
    2:  "minecraft:grass_block",
    3:  "minecraft:dirt",
    4:  "minecraft:cobblestone",
    5:  "minecraft:oak_planks",
    7:  "minecraft:bedrock",
    8:  "minecraft:water",
    9:  "minecraft:water",
    10: "minecraft:lava",
    11: "minecraft:lava",
    12: "minecraft:sand",
    13: "minecraft:gravel",
    14: "minecraft:gold_ore",
    15: "minecraft:iron_ore",
    16: "minecraft:coal_ore",
    17: "minecraft:oak_log",
    18: "minecraft:oak_leaves",
    20: "minecraft:glass",
    21: "minecraft:lapis_ore",
    22: "minecraft:lapis_block",
    24: "minecraft:sandstone",
    25: "minecraft:note_block",
    26: "minecraft:white_bed",
    35: "minecraft:white_wool",
    41: "minecraft:gold_block",
    42: "minecraft:iron_block",
    43: "minecraft:stone_slab",
    44: "minecraft:stone_slab",
    45: "minecraft:bricks",
    46: "minecraft:tnt",
    47: "minecraft:bookshelf",
    48: "minecraft:mossy_cobblestone",
    49: "minecraft:obsidian",
    50: "minecraft:torch",
    52: "minecraft:spawner",
    53: "minecraft:oak_stairs",
    54: "minecraft:chest",
    56: "minecraft:diamond_ore",
    57: "minecraft:diamond_block",
    58: "minecraft:crafting_table",
    61: "minecraft:furnace",
    62: "minecraft:furnace",
    64: "minecraft:oak_door",
    65: "minecraft:ladder",
    66: "minecraft:rail",
    67: "minecraft:cobblestone_stairs",
    73: "minecraft:redstone_ore",
    76: "minecraft:redstone_torch",
    78: "minecraft:snow",
    79: "minecraft:ice",
    80: "minecraft:snow_block",
    81: "minecraft:cactus",
    82: "minecraft:clay",
    86: "minecraft:carved_pumpkin",
    87: "minecraft:netherrack",
    88: "minecraft:soul_sand",
    89: "minecraft:glowstone",
    98: "minecraft:stone_bricks",
    99: "minecraft:brown_mushroom_block",
    100: "minecraft:red_mushroom_block",
    101: "minecraft:iron_bars",
    102: "minecraft:glass_pane",
    103: "minecraft:melon",
    106: "minecraft:vine",
    107: "minecraft:oak_fence_gate",
    108: "minecraft:brick_stairs",
    109: "minecraft:stone_brick_stairs",
    110: "minecraft:mycelium",
    112: "minecraft:nether_bricks",
    113: "minecraft:nether_brick_fence",
    114: "minecraft:nether_brick_stairs",
    120: "minecraft:end_portal_frame",
    121: "minecraft:end_stone",
    123: "minecraft:redstone_lamp",
    125: "minecraft:oak_slab",
    126: "minecraft:oak_slab",
    128: "minecraft:sandstone_stairs",
    129: "minecraft:emerald_ore",
    133: "minecraft:emerald_block",
    134: "minecraft:spruce_stairs",
    135: "minecraft:birch_stairs",
    136: "minecraft:jungle_stairs",
    139: "minecraft:cobblestone_wall",
    155: "minecraft:quartz_block",
    156: "minecraft:quartz_stairs",
    159: "minecraft:terracotta",
    160: "minecraft:glass_pane",
    161: "minecraft:oak_leaves",
    162: "minecraft:oak_log",
    163: "minecraft:acacia_stairs",
    164: "minecraft:dark_oak_stairs",
    168: "minecraft:prismarine",
    169: "minecraft:sea_lantern",
    172: "minecraft:terracotta",
    173: "minecraft:coal_block",
    174: "minecraft:packed_ice",
    179: "minecraft:red_sandstone",
    180: "minecraft:red_sandstone_stairs",
    206: "minecraft:end_stone_bricks",
    213: "minecraft:magma_block",
    214: "minecraft:nether_wart_block",
    215: "minecraft:red_nether_bricks",
    216: "minecraft:bone_block",
}


def parse_schematic_legacy(nbt):
    """Parse MCEdit .schematic (legacy numeric block ID) format."""
    blocks = []

    width  = int(nbt["Width"])
    height = int(nbt["Height"])
    length = int(nbt["Length"])

    info(f"Size: {width}x{height}x{length} (legacy format)")

    block_ids   = bytes(nbt["Blocks"])
    block_data  = bytes(nbt.get("Data", b""))

    unknown_ids = set()

    # MCEdit index: i = y * width * length + z * width + x
    for y in range(height):
        for z in range(length):
            for x in range(width):
                i = y * width * length + z * width + x
                if i >= len(block_ids):
                    continue
                bid = block_ids[i]
                if bid == 0:  # air
                    continue
                name = LEGACY_BLOCK_MAP.get(bid)
                if name is None:
                    unknown_ids.add(bid)
                    name = f"minecraft:stone"  # fallback
                blocks.append((x, y, z, name))

    if unknown_ids:
        info(f"  Warning: {len(unknown_ids)} unknown legacy block IDs mapped to stone: {sorted(unknown_ids)[:20]}")

    return blocks


# ── Auto-detect and dispatch ──────────────────────────────────────────────────

def load_and_parse(path):
    ext = os.path.splitext(path)[1].lower()

    print(f"\nLoading: {path}")

    nbt = nbtlib.load(path)

    if ext == ".litematic":
        print("Format: Litematica (.litematic)")
        return parse_litematic(nbt)

    elif ext == ".schem":
        print("Format: WorldEdit/Sponge (.schem)")
        # nbtlib wraps the root compound under key "" (empty string).
        # Some .schem files also have an explicit "Schematic" key.
        data = nbt
        if "Schematic" in nbt:
            data = nbt["Schematic"]
        elif "" in nbt and isinstance(nbt[""], nbtlib.Compound):
            data = nbt[""]
        return parse_schem(data)

    elif ext == ".schematic":
        print("Format: MCEdit legacy (.schematic)")
        return parse_schematic_legacy(nbt)

    else:
        # Try to auto-detect by NBT keys
        print(f"Unknown extension '{ext}', attempting auto-detect…")
        # nbtlib may wrap the root under "" key
        root = nbt.get("", nbt)
        if "Regions" in nbt:
            print("Detected: Litematica")
            return parse_litematic(nbt)
        elif "Palette" in root and "BlockData" in root:
            print("Detected: Sponge (.schem)")
            return parse_schem(root)
        elif "Blocks" in root and "Width" in root:
            print("Detected: MCEdit legacy")
            return parse_schematic_legacy(root)
        else:
            err(f"Cannot determine schematic format from file: {path}")


# ── Output: CC Builder Lua schematic ─────────────────────────────────────────

LUA_HEADER = """\
-- Auto-generated by convert_schematic.py
-- Source: {source}
-- Blocks: {count}
-- Load in pocket_client.lua with [S] → [Load from file…]
--
-- Coordinates: rx=right, ry=up, rz=forward (turtle facing north = +rz)

return {{
  name   = {name},
  blocks = {{
"""

LUA_ENTRY  = "    {{rx={rx:5d}, ry={ry:5d}, rz={rz:5d}, block={block}}},\n"
LUA_FOOTER = "  },\n}\n"


def write_lua(blocks, out_path, source_name, origin_shift=None, filter_str=None):
    """Write a CC Builder Lua schematic file."""

    if origin_shift:
        ox, oy, oz = origin_shift
        blocks = [(x - ox, y - oy, z - oz, b) for x, y, z, b in blocks]

    # Normalise: shift so minimum coords are (0,0,0)
    if blocks:
        min_x = min(b[0] for b in blocks)
        min_y = min(b[1] for b in blocks)
        min_z = min(b[2] for b in blocks)
        blocks = [(x - min_x, y - min_y, z - min_z, b) for x, y, z, b in blocks]

    if filter_str:
        blocks = [b for b in blocks if filter_str in b[3]]
        info(f"After filter '{filter_str}': {len(blocks)} blocks")

    name = os.path.splitext(os.path.basename(source_name))[0]
    lua_name = '"' + name.replace('"', '\\"') + '"'

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(LUA_HEADER.format(
            source=source_name,
            count=len(blocks),
            name=lua_name,
        ))
        for x, y, z, block in blocks:
            # Lua strings need quoting
            f.write(LUA_ENTRY.format(
                rx=x, ry=y, rz=z,
                block='"' + block.replace('"', '\\"') + '"',
            ))
        f.write(LUA_FOOTER)

    return len(blocks)


# ── Stats ─────────────────────────────────────────────────────────────────────

def print_stats(blocks):
    from collections import Counter
    counts = Counter(b[3] for b in blocks)
    print("\n── Block summary ──────────────────────────────")
    for name, count in sorted(counts.items(), key=lambda x: -x[1]):
        bar = "█" * min(30, count // max(1, max(counts.values()) // 30))
        print(f"  {count:6d}  {name:<45s}  {bar}")
    print(f"  ──────")
    print(f"  {len(blocks):6d}  TOTAL")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Convert Minecraft schematics to CC Builder Lua format",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("input",  help="Input .litematic / .schem / .schematic file")
    parser.add_argument("output", nargs="?", help="Output .lua file (default: same name)")
    parser.add_argument("--filter", metavar="BLOCK", help="Only include blocks containing this string")
    parser.add_argument("--origin", metavar="X,Y,Z", help="World coords to use as (0,0,0) origin")
    parser.add_argument("--stats",  action="store_true", help="Print block count summary")

    args = parser.parse_args()

    if not os.path.exists(args.input):
        err(f"File not found: {args.input}")

    origin_shift = None
    if args.origin:
        try:
            parts = [int(p.strip()) for p in args.origin.split(",")]
            if len(parts) != 3:
                raise ValueError
            origin_shift = tuple(parts)
        except ValueError:
            err("--origin must be three comma-separated integers, e.g. 100,64,200")

    out_path = args.output
    if not out_path:
        base = os.path.splitext(args.input)[0]
        out_path = base + ".lua"

    # Parse
    blocks = load_and_parse(args.input)

    info(f"Total non-air blocks: {len(blocks)}")

    if args.stats:
        print_stats(blocks)

    if not blocks:
        err("No blocks found in schematic (or all blocks are air)")

    # Write
    count = write_lua(
        blocks,
        out_path,
        source_name=os.path.basename(args.input),
        origin_shift=origin_shift,
        filter_str=args.filter,
    )

    # Summary
    if blocks:
        xs = [b[0] for b in blocks]
        ys = [b[1] for b in blocks]
        zs = [b[2] for b in blocks]
        print(f"\n✔ Written {count} blocks to: {out_path}")
        print(f"  Dimensions: {max(xs)-min(xs)+1} x {max(ys)-min(ys)+1} x {max(zs)-min(zs)+1}  (X × Y × Z)")
        print(f"  Lua file size: {os.path.getsize(out_path) // 1024} KB")
        print(f"\nCopy {out_path} to a disk in Minecraft, then load it")
        print(f"in pocket_client.lua with [S] → Load from file.")


if __name__ == "__main__":
    main()
