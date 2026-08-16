#!/usr/bin/env python3
"""Build Data/DungeonTeleports.lua from the local travel-ability source.

WHY THIS MATTERS MORE THAN ITS SIZE. The route is led by INSTANCE goals, and a
player who has earned a dungeon teleport reaches that instance door instantly
from anywhere in the world. We modelled 19 teleport spells in total; this
source states 76 dungeon and raid teleports alone, each with the spell id the
client can be asked about and the destination it lands on.

Nothing here is assumed to be OWNED. The spell id is what makes that checkable:
the addon asks IsPlayerSpell for every one of them, so a teleport nobody has
earned never shortens anybody's route.

Destinations are joined against the travel network we already ship, so each one
resolves to a real place with a map and a coordinate rather than an opaque key.
A teleport whose destination cannot be resolved is DROPPED and counted, not
carried with a guessed location.
"""
import re
import pathlib
import sys

SRC = pathlib.Path.home() / "Downloads/Mapzeroth/PlayerAbilities.lua"
NET = pathlib.Path(__file__).resolve().parent.parent / "Data/TravelNetwork.lua"
OUT = pathlib.Path(__file__).resolve().parent.parent / "Data/DungeonTeleports.lua"


def lua_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main():
    if not SRC.exists():
        sys.exit("source not found: %s" % SRC)
    if not NET.exists():
        sys.exit("travel network not built yet: %s" % NET)

    # The nodes we already ship: KEY -> (name, mapID, x, y)
    net = NET.read_text(encoding="utf-8", errors="replace")
    nodes = {}
    for m in re.finditer(
            r'\["([A-Z0-9_]+)"\]=\{name="((?:[^"\\]|\\.)*)",mapID=(\d+),'
            r'x=([\d.]+),y=([\d.]+)', net):
        nodes[m.group(1)] = (m.group(2), int(m.group(3)),
                             float(m.group(4)), float(m.group(5)))

    text = SRC.read_text(encoding="utf-8", errors="replace")
    blocks = re.findall(r"\{\s*id\s*=\s*\"([^\"]+)\",(.*?)\n\s*\},", text, re.S)

    kept, unresolved, notdungeon = [], [], 0
    for bid, body in blocks:
        def field(pat):
            m = re.search(pat, body)
            return m.group(1) if m else None

        spell = field(r"spellID\s*=\s*(\d+)")
        dest = field(r'destination\s*=\s*"([^"]+)"')
        name = field(r'name\s*=\s*"([^"]+)"')
        cd = field(r"cooldown\s*=\s*(\d+)")
        cast = field(r"castTime\s*=\s*(\d+)")
        if not (spell and dest and name):
            continue
        # Siege of Boralus and the MOTHERLODE have SEPARATE Alliance and Horde
        # entrances, so one spell carries two destinations and a plain
        # endswith("_DUNGEON") test dropped all four of them without a word.
        faction = None
        base = dest
        for suffix, fac in (("_ALLIANCE", "Alliance"), ("_HORDE", "Horde")):
            if base.endswith(suffix):
                base, faction = base[: -len(suffix)], fac
                break
        if not (base.endswith("_DUNGEON") or base.endswith("_RAID")):
            notdungeon += 1
            continue
        hit = nodes.get(dest)
        if not hit:
            unresolved.append((name, dest))
            continue
        place, mapid, x, y = hit
        # The network stores 0..1; the rest of the addon uses 0..100.
        if x <= 1.0:
            x *= 100
        if y <= 1.0:
            y *= 100
        kept.append({
            "spell": int(spell), "name": name, "place": place,
            "mapID": mapid, "x": round(x, 2), "y": round(y, 2),
            "cooldown": int(cd) if cd else None,
            "cast": int(cast) if cast else None,
            "faction": faction,
        })

    print("  teleport blocks parsed      : %d" % len(blocks))
    print("  dungeon/raid teleports      : %d" % (len(kept) + len(unresolved)))
    print("  resolved to a real place    : %d" % len(kept))
    print("  DROPPED, destination unknown: %d" % len(unresolved))
    for n, d in unresolved[:8]:
        print("     %-38s %s" % (n[:38], d))
    if len(unresolved) > 8:
        print("     ...and %d more" % (len(unresolved) - 8))

    out = [
        "-- MasterMounts: dungeon and raid teleports, by spell id.",
        "--",
        "-- The route is led by INSTANCE goals, and a player who has earned one",
        "-- of these reaches that door instantly from anywhere. Modelling them is",
        "-- worth more to a route than any number of flight paths.",
        "--",
        "-- NOTHING HERE IS ASSUMED TO BE OWNED. Every entry carries the spell id,",
        "-- so the addon asks the client whether this character actually has it;",
        "-- a teleport nobody earned never shortens anybody's route.",
        "--",
        "-- %d teleports, each resolved against the shipped travel network to a"
        % len(kept),
        "-- real map and coordinate. %d more were DROPPED because their"
        % len(unresolved),
        "-- destination did not resolve -- an unplaceable teleport is left out",
        "-- rather than pointed at a guess.",
        "--",
        "-- Generated by tools/extract_dungeon_teleports.py. Do not hand-edit.",
        "local _, MM = ...",
        "",
        "MM.DungeonTeleports = {",
    ]
    for t in sorted(kept, key=lambda r: r["name"]):
        bits = ['spell=%d' % t["spell"],
                'name="%s"' % lua_escape(t["name"]),
                'place="%s"' % lua_escape(t["place"]),
                "mapID=%d" % t["mapID"], "x=%.2f" % t["x"], "y=%.2f" % t["y"]]
        if t["cooldown"]:
            bits.append("cooldown=%d" % t["cooldown"])
        if t["cast"]:
            bits.append("cast=%d" % t["cast"])
        if t["faction"]:
            bits.append('faction="%s"' % t["faction"])
        out.append("\t{%s}," % ",".join(bits))
    out.append("}")

    OUT.write_text("\n".join(out) + "\n")
    print("  wrote %s  %.0f KB" % (OUT.name, OUT.stat().st_size / 1024))


if __name__ == "__main__":
    main()
