#!/usr/bin/env python3
"""Spawn points for mounts, read out of the HandyNotes plugin data.

ONLY NODES THAT LEAD TO A MOUNT. A HandyNotes zone file describes hundreds of
points -- transmog, reputation, achievements, profession trainers -- and none of
those belong in a mount database. A node is kept here only when its rewards name
a mount, which the plugins say in one of exactly two ways:

    Mount({item = 257152, id = 2760})     -- the "Notes" framework
    loot = {{252017, mount = true}}       -- the handler framework

The mount is then matched to our own record by ITEM ID, never by name: the item
id is what both sides already carry, and a name match would quietly attach the
wrong record the first time someone reworded one.

Coordinates are packed into the node's table key -- map.nodes[34413305] is
34.41, 33.05 -- which is the same encoding HandyNotes itself decodes in
HandyNotes.lua, and the same points already sitting in Data_99n_RareSpawns.lua.
That file was built from this source by hand; this reproduces it and covers the
zones it did not reach.

Nothing is invented. A node with no mount reward, an item id our database does
not know, or a map we cannot resolve is COUNTED AND REPORTED, never guessed at.

Usage:  python3 tools/extract_handynotes_mounts.py [--write]
        Without --write it only reports. With --write it rewrites
        Data/_source/Data_99o_HandyNotesSpawns.lua.
"""
import collections
import glob
import os
import re
import sys

PLUGINS = os.path.expanduser("~/Downloads")
OUT = "Data/_source/Data_99o_HandyNotesSpawns.lua"

# ---------------------------------------------------------------------------
# Our own records: itemID -> mount name, and what each already knows about
# where it is. Parsed from the flat build, which is the file the addon loads.
# ---------------------------------------------------------------------------
def our_records():
    src = open("Data/Mounts.lua", encoding="utf-8").read()
    recs, cur, depth, inrec = [], [], 0, False
    for line in src.split("\n"):
        if not inrec and re.match(r"^\t\{\s*$", line):
            inrec, cur, depth = True, [line], 1
            continue
        if inrec:
            cur.append(line)
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                recs.append("\n".join(cur))
                inrec = False

    def block(rec, key):
        m = re.search(r"\n\t\t" + key + r" = \{", rec)
        if not m:
            return None
        i, d, j = m.end() - 1, 0, m.end() - 1
        while j < len(rec):
            if rec[j] == "{":
                d += 1
            elif rec[j] == "}":
                d -= 1
                if d == 0:
                    return rec[i:j + 1]
            j += 1
        return None

    by_item, placed = {}, {}
    for rec in recs:
        nm = re.search(r'\n\t\tname = "(.*?)"', rec)
        if not nm:
            continue
        name = nm.group(1)
        # every item id the record carries, including alternate sources
        for m in re.finditer(r"\n\t+itemID = (\d+)", rec):
            by_item.setdefault(int(m.group(1)), name)
        zone, spawns = block(rec, "zone"), block(rec, "spawns")
        has = bool((spawns and re.search(r"x = [\d.]+", spawns))
                   or (zone and re.search(r"x = [\d.]+", zone)))
        placed[name] = has
    return by_item, placed


# ---------------------------------------------------------------------------
# Plugin parsing
# ---------------------------------------------------------------------------
MOUNT_PATTERNS = (
    re.compile(r"Mount\(\{\s*item\s*=\s*(\d+)"),
    re.compile(r"\{\s*(\d+)\s*,\s*mount\s*="),
)


def mounts_in(body):
    """[(itemID, label)] -- the label is the plugin's own trailing comment, kept
    FOR THE REPORT ONLY. Matching is by item id; a name is what you print when
    you have to tell someone which item id went unrecognised."""
    out = []
    for pat in MOUNT_PATTERNS:
        for m in pat.finditer(body):
            tail = body[m.end():m.end() + 120]
            label = re.search(r"--\s*([^\n]{2,60})", tail)
            out.append((int(m.group(1)),
                        label.group(1).strip() if label else ""))
    return out


def balanced(text, start):
    """Text of the {...} or (...) group beginning at `start`."""
    open_ch = text[start]
    close_ch = {"{": "}", "(": ")"}[open_ch]
    d, j = 0, start
    while j < len(text):
        if text[j] == open_ch:
            d += 1
        elif text[j] == close_ch:
            d -= 1
            if d == 0:
                return text[start:j + 1]
        j += 1
    return text[start:]


def unpack(coord):
    s = str(coord).zfill(8)
    return int(s[:4]) / 100.0, int(s[4:]) / 100.0


def parse_plugin(root):
    """[(itemID, mapID, x, y)], plus counters for what was skipped."""
    found = []
    skipped = collections.Counter()

    consts = {}
    for path in glob.glob(root + "/**/*.lua", recursive=True):
        text = open(path, encoding="utf-8", errors="replace").read()
        for m in re.finditer(r"ns\.([A-Z][A-Z_0-9]*)\s*=\s*(\d+)\s*$",
                             text, re.M):
            consts[m.group(1)] = int(m.group(2))

    for path in glob.glob(root + "/**/*.lua", recursive=True):
        text = open(path, encoding="utf-8", errors="replace").read()

        # Style A: `local map = Map({id = 2437})` then `map.nodes[COORD] = X({...})`
        maps = {m.group(1): int(m.group(2)) for m in
                re.finditer(r"local\s+(\w+)\s*=\s*Map\(\{\s*id\s*=\s*(\d+)", text)}
        for m in re.finditer(r"(\w+)\.nodes\[(\d{5,8})\]\s*=\s*\w+\s*(\()", text):
            var, coord = m.group(1), int(m.group(2))
            mapID = maps.get(var)
            body = balanced(text, m.start(3))
            items = mounts_in(body)
            if not items:
                continue
            if not mapID:
                skipped["node whose map could not be resolved"] += 1
                continue
            x, y = unpack(coord)
            for item, label in items:
                found.append((item, mapID, x, y, label))

        # Style B: `ns.RegisterPoints(ns.HARANDAR, { [COORD] = {...} })`
        for m in re.finditer(r"RegisterPoints\(\s*ns\.([A-Z][A-Z_0-9]*)\s*,\s*(\{)",
                             text):
            mapID = consts.get(m.group(1))
            table = balanced(text, m.start(2))
            if not mapID:
                skipped["RegisterPoints on an unresolved map constant"] += 1
                continue
            # top-level [COORD] = { ... } only; `related` holds nested coords
            # that belong to the same node, not to a mount of their own
            depth, i = 0, 0
            while i < len(table):
                ch = table[i]
                if ch in "{(":
                    depth += 1
                    if depth == 2:
                        # we are entering a node body; find its key behind us
                        key = re.search(r"\[(\d{5,8})\]\s*=\s*$", table[:i])
                        if key:
                            body = balanced(table, i)
                            for item, label in mounts_in(body):
                                x, y = unpack(int(key.group(1)))
                                found.append((item, mapID, x, y, label))
                            i += len(body)
                            depth -= 1
                            continue
                elif ch in "})":
                    depth -= 1
                i += 1
    return found, skipped


def main():
    by_item, placed = our_records()
    per_mount = collections.defaultdict(list)
    unmatched, skipped_all = collections.Counter(), collections.Counter()
    plugins = sorted(d for d in glob.glob(PLUGINS + "/HandyNotes*")
                     if os.path.isdir(d))
    if not plugins:
        print(f"no HandyNotes plugin folders under {PLUGINS}")
        return 1

    for root in plugins:
        found, skipped = parse_plugin(root)
        skipped_all.update(skipped)
        named = 0
        for item, mapID, x, y, label in found:
            name = by_item.get(item)
            if not name:
                unmatched[(item, label)] += 1
                continue
            named += 1
            pt = (mapID, x, y)
            if pt not in per_mount[name]:
                per_mount[name].append(pt)
        print(f"  {os.path.basename(root):<34} {len(found):>5} mount node(s), "
              f"{named:>5} matched to a record")

    gaps = {n: p for n, p in per_mount.items() if not placed.get(n, True)}
    already = {n: p for n, p in per_mount.items() if placed.get(n, True)}
    print(f"\n  {len(per_mount)} mounts have spawn points in HandyNotes")
    print(f"  {len(gaps)} of them carry NO coordinate in our data -- the gap this fills")
    print(f"  {len(already)} already have one and are left alone")
    print(f"  {sum(unmatched.values())} node reward(s) name an item our database "
          f"does not know ({len(unmatched)} distinct items):")
    for (item, label), n in sorted(unmatched.items(), key=lambda kv: -kv[1]):
        print(f"     item {item:<8} x{n:<3} HandyNotes calls it: {label or '(unnamed)'}")
    for what, n in skipped_all.most_common():
        print(f"  {n} skipped: {what}")

    if gaps:
        print("\n  would add:")
        for name in sorted(gaps):
            pts = gaps[name]
            print(f"     {name:<34} {len(pts):>3} point(s) on map "
                  f"{sorted({p[0] for p in pts})}")

    if "--write" not in sys.argv:
        print("\n  (report only -- pass --write to update the source file)")
        return 0

    lines = [
        "-- MasterMounts: spawn points for mounts that had none, read from the",
        "-- HandyNotes plugin data by tools/extract_handynotes_mounts.py.",
        "--",
        "-- ONLY nodes whose rewards name a mount are here, matched to our records",
        "-- by ITEM ID rather than by name. Records that already carry a coordinate",
        "-- are left exactly as they were -- this file fills gaps and nothing else.",
        "-- Regenerate rather than editing by hand.",
        "local _, MM = ...",
        "",
    ]
    for name in sorted(gaps):
        pts = ", ".join("{ mapID = %d, x = %g, y = %g }" % p for p in gaps[name])
        lines.append('MM.OverrideMount(%s, { spawns = { %s } }) -- %d point(s)'
                     % (lua_str(name), pts, len(gaps[name])))
    lines.append("")
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    print(f"\n  wrote {OUT} ({len(gaps)} records)")
    return 0


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


if __name__ == "__main__":
    sys.exit(main())
