#!/usr/bin/env python3
"""Makes Empyrean Tower break (kept as a record; a second run changes nothing).

The tower was built with only its stained glass breakable. This edits
game/maps/empyrean.tscn and game/maps/palettes/empyrean.tres as text:

 - the map gets fine destruction, and walls and floors up to a metre thick break
   (MapRoot.break_thickness): the outer wall is a metre of stone, the tier floors 0.8;
 - every solid, drawn box of the tower's walls, floors, outer wall, balconies and shaft
   bridges gets `breakable = true` (WHAT: which kinds, under which nodes), with a
   toughness for each kind in the palette (TOUGHNESS) and bigger pieces for the floors
   (SCALE: the tower has some 37,000 square metres of floor);
 - each tier gets a MapFrame (a child of the map, `Frame<tier>`): held up by its walls,
   to the ground, on a square grid of bays about 7.5 m across laid over the round plan.
   All six share the same parts (the tier nodes, the balconies and the bridges), and
   each claims what lies between its own floor and the next one up (MapFrame.claim), so
   a tier is a building standing on its floor: its rooms, storeys and upper hall can
   come down, a section at a time, and the tier floor it stands on stays (it only
   breaks). A section's floor also caves in once 40% of it is shot away
   (MapFrame.cave_share): that is how a bridge over the shaft is brought down. The ribs outside the wall (Exterior/Ribs) are no part of it and stand
   whatever happens.

    python3 tools/arena/empyrean_destruction.py
"""
import os
import re

HERE = os.path.dirname(__file__)
SCENE = os.path.join(HERE, "..", "..", "game", "maps", "empyrean.tscn")
PALETTE = os.path.join(HERE, "..", "..", "game", "maps", "palettes", "empyrean.tres")
FRAME_SCRIPT = '[ext_resource type="Script" path="res://game/arena/map_frame.gd" id="22_frame"]\n'

TIER = 30.5
TIERS = ["ArcaneEngine", "GrandLibrary", "AlchemyLabs", "Menagerie", "SummoningChamber", "Observatory"]
L1, L2, L3 = 6.35, 12.7, 19.0
GALLERY = 9.0             # the Observatory's gallery, above its floor
R_FOOT, R_TOP, TOP = 30.5, 20.0, 183.0
BAY = 7.5                 # about how far across a bay is
CAVE = 0.4                # a bay's floor caves in once this much of it is shot away
MAX_THICKNESS = 1.0
SMALL_AREA = 0.4
FLOORS = {"stone_floor", "floor_engine", "floor_library", "floor_labs", "floor_menagerie", "floor_summoning",
          "floor_observatory", "alloy_floor", "catwalk", "brass"}
# a node path's ending (after the tier, if any) -> the kinds that break under it
WHAT = {
    "/Walls": {"stone", "stone_dark"},
    "/Floors": FLOORS,
    "/Shell/Wall": {"stone"},
    "Exterior/Balconies": {"stone_floor", "brass"},
    "Shaft/Bridges": {"stone_floor", "alloy_floor", "brass"},
}
TOUGHNESS = {
    "stone": 200.0, "stone_dark": 220.0, "stone_floor": 260.0, "floor_engine": 260.0, "floor_library": 260.0,
    "floor_labs": 260.0, "floor_menagerie": 260.0, "floor_summoning": 260.0, "floor_observatory": 260.0,
    "alloy_floor": 300.0, "catwalk": 140.0, "brass": 120.0,
}
SCALE = {"stone_floor": 1.6, "floor_engine": 1.6, "floor_library": 1.6, "floor_labs": 1.6, "floor_menagerie": 1.6,
         "floor_summoning": 1.6, "floor_observatory": 1.6, "alloy_floor": 1.6}
BEFORE = ("shape", "size", "kind", "sides", "inner", "arc", "solid", "drawn", "material_type")   # a block's settings that come before Breakable
ROOT_SETTINGS = ["fine_destruction = true", "break_thickness = 1.0"]


def num(x):
    return ("%.2f" % x).rstrip("0").rstrip(".")


def ro(y):
    """The wall's outer face at height y."""
    return R_FOOT - (R_FOOT - R_TOP) * (y / TOP)


def frame(i):
    y0 = TIER * i
    half = ro(y0) + 0.5
    n = round(2.0 * half / BAY)
    lines = [-half + 2.0 * half * k / n for k in range(n + 1)]
    tops = [y0 + GALLERY] if i == len(TIERS) - 1 else [y0 + L1, y0 + L2, y0 + L3]
    height = 60.0 if i == len(TIERS) - 1 else TIER
    parts = ["../" + t for t in TIERS] + ["../Exterior/Balconies", "../Shaft/Bridges"]
    return "\n".join([
        '[node name="Frame%s" type="Node3D" parent="."]' % TIERS[i],
        'script = ExtResource("22_frame")',
        "parts = Array[NodePath]([%s])" % ", ".join('NodePath("%s")' % p for p in parts),
        "claim = AABB(-200, %s, -200, 400, %s, 400)" % (num(y0 - 1.0), num(height)),
        "lines_x = PackedFloat32Array(%s)" % ", ".join(num(x) for x in lines),
        "lines_z = PackedFloat32Array(%s)" % ", ".join(num(x) for x in lines),
        "floor_tops = PackedFloat32Array(%s)" % ", ".join(num(t) for t in tops),
        "held_by_walls = true",
        "wall_reach = 3.0",
        "to_the_ground = true",
        "ground = %s" % num(y0 - 0.05),
        "cave_share = %s" % num(CAVE),
        'spans = Array[NodePath]([NodePath("../Shaft/Bridges")])',
        "", ""])


def table(text, name, kind, values, fmt):
    """Adds `values` to the palette's dictionary `name` (making it if need be)."""
    head = "%s = Dictionary[String, %s]({" % (name, kind)
    if head not in text:
        at = text.index("material = Dictionary[String, String]({")
        text = text[:at] + head + "\n})\n" + text[at:]
    start = text.index(head) + len(head)
    end = text.index("})", start)
    have = dict(re.findall(r'"([^"]+)": ([^,\n]+)', text[start:end]))
    for k, v in values.items():
        have.setdefault(k, fmt(v))
    body = ",\n".join('"%s": %s' % (k, have[k]) for k in sorted(have))
    return text[:start] + "\n" + body + "\n" + text[end:]


def main():
    with open(SCENE) as fh:
        text = fh.read()
    block_id = re.search(r'path="res://game/arena/map_block\.gd" id="([^"]+)"', text).group(1)
    parts = re.split(r"(?m)^(?=\[)", text)
    ticked = {}
    for n, part in enumerate(parts):
        if part.startswith('[node name="EmpyreanTower" '):
            lines = part.rstrip("\n").split("\n")
            for setting in ROOT_SETTINGS:
                if setting.split(" = ")[0] + " = " not in part:
                    lines.append(setting)
            parts[n] = "\n".join(lines) + "\n\n"
            continue
        if not part.startswith("[node ") or 'script = ExtResource("%s")' % block_id not in part:
            continue
        lines = part.split("\n")
        head = re.match(r'\[node name="([^"]+)" type="[^"]+" parent="([^"]+)"', lines[0])
        if not head:
            continue
        kinds = None
        for ending, allowed in WHAT.items():
            if head.group(2).endswith(ending):
                kinds = allowed
        if kinds is None:
            continue
        props = {}
        for i, line in enumerate(lines):
            m = re.match(r"^(\w+) = (.*)$", line)
            if m:
                props[m.group(1)] = (i, m.group(2))
        kind = props.get("kind", (0, '"concrete"'))[1].strip('"')
        if "breakable" in props or kind not in kinds:
            continue
        if props.get("shape", (0, "0"))[1] != "0" or props.get("solid", (0, "true"))[1] != "true" or props.get("drawn", (0, "true"))[1] != "true":
            continue
        size = re.match(r"Vector3\(([^)]*)\)", props.get("size", (0, "Vector3(1, 1, 1)"))[1])
        dims = sorted(float(v) for v in size.group(1).split(","))
        if dims[0] > MAX_THICKNESS + 0.0005 or dims[1] * dims[2] < SMALL_AREA:
            continue
        after = max(props[name][0] for name in BEFORE if name in props)
        lines.insert(after + 1, "breakable = true")
        parts[n] = "\n".join(lines)
        ticked[kind] = ticked.get(kind, 0) + 1
    text = "".join(parts)
    if FRAME_SCRIPT not in text:
        last = text.rfind("[ext_resource ")
        end = text.index("\n", last) + 1
        text = text[:end] + FRAME_SCRIPT + text[end:]
    framed = []
    for i, tier in enumerate(TIERS):
        want = frame(i).rstrip("\n") + "\n"
        head = '[node name="Frame%s" ' % tier
        if head not in text:
            text = text.rstrip("\n") + "\n\n" + want
            framed.append(tier)
        else:   # (written again as this file says: its settings are this file's)
            start = text.index(head)
            end = text.find("\n[", start)
            end = len(text) if end < 0 else end + 1
            have = text[start:end].rstrip("\n") + "\n"
            if have != want:
                text = text[:start] + want + ("\n" if end < len(text) else "") + text[end:]
                framed.append(tier)
    with open(SCENE, "w") as fh:
        fh.write(text)
    with open(PALETTE) as fh:
        pal = fh.read()
    new = table(pal, "breakable", "float", TOUGHNESS, lambda v: "%.1f" % v)
    new = table(new, "break_scale", "float", SCALE, lambda v: "%.1f" % v)
    if new != pal:
        with open(PALETTE, "w") as fh:
            fh.write(new)
    print("ticked:", ", ".join("%s %d" % (k, ticked[k]) for k in sorted(ticked)) or "nothing")
    print("framed:", ", ".join(framed) or "nothing")


if __name__ == "__main__":
    main()
