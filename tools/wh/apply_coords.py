#!/usr/bin/env python3
"""Merge harvested Wowhead coordinates into an override file.

Only rows with an explicit uiMapId AND a single zone are written. Wowhead's
outer g_mapperData key is its own internal zone id, NOT the WoW map id -- a
coordinate without uiMapId has no map to belong to, so it is dropped, not
guessed. Ambiguous names and multi-zone spawns go to review.txt.
"""
import json, pathlib, re
from collections import defaultdict

base    = pathlib.Path.home()/"Downloads/MasterMountsWorldTour/tools/wh"
harvest = json.loads((base/"harvest.json").read_text())
work    = json.loads((base/"worklist.json").read_text())

by_npc = {h["npc"]: h for h in harvest}
mounts = defaultdict(list)
for m in work:
    if m["npc"]: mounts[m["npc"]].append(m)

def esc(s): return s.replace("\\","\\\\").replace('"','\\"')

# Existing coordinates already in the data, keyed by the NPC named in the prose.
# If Wowhead disagrees with a sibling bought from the same NPC, applying it would
# leave one mount stranded away from the rest -- a contradiction we introduced.
# Flag it instead; a human decides which value is the wrong one.
existing = defaultdict(set)
for f in (pathlib.Path.home()/"Downloads/MasterMountsWorldTour/Data/_source").glob("*.lua"):
    for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
        z = re.search(r'zone\s*=\s*\{[^}]*mapID\s*=\s*(\d+)[^}]*x\s*=\s*([\d.]+)[^}]*y\s*=\s*([\d.]+)', line)
        if not z: continue
        for m in work:
            pass
        src = re.search(r'source\s*=\s*"((?:[^"\\]|\\.)*)"', line)
        if not src: continue
        for npc in mounts:
            if npc in src.group(1):
                existing[npc].add((int(z.group(1)), float(z.group(2)), float(z.group(3))))

# Truth about what already has a coordinate comes from the built data, not from
# the line-level source scan -- multi-line records fooled that scan into calling
# curated values "missing". Filling a gap is what was asked for; silently moving
# an existing coordinate is a different and much larger change.
FLAT = pathlib.Path.home()/"Downloads/MasterMountsWorldTour/Data/Mounts.lua"
has_coord, _cur = set(), None
for _l in FLAT.read_text(encoding="utf-8", errors="replace").splitlines():
    _m = re.match(r'\s*name\s*=\s*"((?:[^"\\]|\\.)*)",', _l)
    if _m and (len(_l)-len(_l.lstrip())) <= 2:
        _cur = _m.group(1)
    elif _cur and re.match(r'\s*x\s*=\s*[\d.]+,', _l):
        has_coord.add(_cur)

lines, review, applied, replaced = [], [], 0, []
for npc, h in sorted(by_npc.items()):
    ms = mounts.get(npc, [])
    ok = (h.get("status") == "ok"
          and isinstance(h.get("best"), dict)
          and isinstance(h["best"].get("uiMapId"), int)
          and h["best"].get("zone"))
    if not ok:
        why = h.get("status","?")
        extra = ""
        if h.get("ids"):  extra = f"  ids={h['ids']}"
        if h.get("maps"): extra = f"  maps={h['maps']}"
        for m in ms:
            review.append(f'{m["mount"][:36]:<36} {npc:<24} {why}{extra}')
        continue
    b = h["best"]
    sib = existing.get(npc)
    if sib:
        near = any(mp == b["uiMapId"] and abs(x-b["x"]) < 3 and abs(y-b["y"]) < 3 for mp,x,y in sib)
        if not near:
            for m in ms:
                review.append(f'{m["mount"][:36]:<36} {npc:<24} CONFLICT wowhead=({b["uiMapId"]},{b["x"]},{b["y"]}) ours={sorted(sib)}')
            continue
    for m in ms:
        if m["mount"] in has_coord:
            replaced.append(f'{m["mount"][:36]:<36} {npc:<24} already has a coord; '
                            f'wowhead offers ({b["uiMapId"]},{b["x"]},{b["y"]})')
            continue
        lines.append(
            f'MM.OverrideMount("{esc(m["mount"])}", {{ zone = {{ name = "{esc(b["zone"])}", '
            f'mapID = {b["uiMapId"]}, x = {b["x"]}, y = {b["y"]} }} }}) '
            f'-- {npc} (npc={h["id"]})')
        applied += 1

hdr = ("-- MasterMounts: NPC coordinates harvested from Wowhead g_mapperData.\n"
       "-- Written ONLY for unambiguous, single-zone NPCs that carry an explicit\n"
       "-- uiMapId. Multi-zone, ambiguous-name and map-less spawns are deliberately\n"
       "-- left blank -- an empty field is honest, a guessed coordinate is not.\n"
       "-- See tools/wh/review.txt for what was skipped and why.\n"
       "local _, MM = ...\n\n")
(base/"Data_99m_WowheadCoords.lua").write_text(hdr + "\n".join(lines) + "\n")
(base/"review.txt").write_text("\n".join(sorted(review)) + "\n")

tally = defaultdict(int)
for h in by_npc.values(): tally[h.get("status","?")] += 1
print("npc results:", dict(tally))
print(f"mount overrides written : {applied}")
(base/"refinements.txt").write_text("\n".join(sorted(replaced)) + "\n")
print(f"left for review         : {len(review)}")
print(f"skipped (already had a coord, see refinements.txt) : {len(replaced)}")
