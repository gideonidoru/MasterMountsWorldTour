#!/usr/bin/env python3
"""Apply Wowhead coordinates as authoritative.

Wowhead's live spawn data wins over anything we hold, including hand-entered
values -- so a mount whose source names a resolved NPC takes that NPC's
coordinates whether or not it already had some. Resolving per NPC (not per
zone) also keeps faction-split vendors correct: each faction's quartermaster
resolves separately, so Alliance and Horde land at their own pavilions.

Still refused: multi-zone NPCs, ambiguous names, and spawns with no uiMapId --
Wowhead being authoritative does not make a guess into a fact.
"""
import json, pathlib, re
from collections import defaultdict

base = pathlib.Path(__file__).parent
harvest = {h["npc"]: h for h in json.loads((base/"harvest.json").read_text())}
for extra in ("harvest2.json",):
    p = base/extra
    if p.exists():
        for h in json.loads(p.read_text()): harvest[h["npc"]] = h

# Zygor's NPCData is a local, rate-limit-free source for service NPCs (vendors,
# trainers). It carries the WoW mapID directly and a faction side. Wowhead stays
# authoritative where it answered; Zygor fills the gaps it left. The two agreed
# on 11/11 NPCs they both knew, so using one to backfill the other is sound.
zygor = json.loads((base/"zygor_npcs.json").read_text())
# RareScanner covers what Zygor does not: world rares. Coordinates are stored as
# integers scaled by 100 and are keyed by uiMapID, already normalised on import.
rares = json.loads((base/"rarescanner_npcs.json").read_text())

work = json.loads((base/"worklist2.json").read_text())
mounts = defaultdict(list)
for m in work: mounts[m["npc"]].append(m)

def esc(s): return s.replace("\\","\\\\").replace('"','\\"')

lines, review, applied, changed = [], [], 0, 0
for npc, ms in sorted(mounts.items()):
    h = harvest.get(npc)
    ok = (h and h.get("status") == "ok" and isinstance(h.get("best"), dict)
          and isinstance(h["best"].get("uiMapId"), int) and h["best"].get("zone"))
    if not ok and npc in zygor:
        ents = zygor[npc]
        spots = {(e["mapID"], e["x"], e["y"]) for e in ents}
        if len(spots) == 1:
            e = ents[0]
            h = {"status":"ok", "id":e["id"], "src":"zygor",
                 "best":{"uiMapId":e["mapID"], "zone":e["zone"], "x":e["x"], "y":e["y"]}}
            ok = True
    if not ok and npc in rares:
        e = rares[npc]
        h = {"status":"ok", "id":e["id"], "src":"rarescanner",
             "best":{"uiMapId":e["mapID"], "zone":None, "x":e["x"], "y":e["y"]}}
        ok = True
    if not ok:
        why = (h or {}).get("status", "not harvested")
        ids = f"  ids={h['ids']}" if h and h.get("ids") else ""
        for m in ms:
            review.append(f'{m["mount"][:36]:<36} {npc:<26} {why}{ids}')
        continue
    b = h["best"]
    for m in ms:
        zn = f'name = "{esc(b["zone"])}", ' if b.get("zone") else ""
        lines.append(
            f'MM.OverrideMount("{esc(m["mount"])}", {{ zone = {{ {zn}'
            f'mapID = {b["uiMapId"]}, x = {b["x"]}, y = {b["y"]} }} }}) '
            f'-- {npc} (npc={h["id"]}, {h.get("src","wowhead")})')
        applied += 1
        if m["hasxy"]: changed += 1

hdr = ("-- MasterMounts: NPC coordinates from Wowhead (authoritative).\n"
       "-- Resolved per NPC rather than per zone, which keeps faction-split\n"
       "-- vendors correct -- each faction's quartermaster resolves separately.\n"
       "-- NOT written: ambiguous names, multi-zone NPCs, and spawns carrying no\n"
       "-- uiMapId (Wowhead's outer key is its own zone id, not the WoW map id).\n"
       "-- See FAILURES.txt for everything skipped and why.\n"
       "local _, MM = ...\n\n")
(base/"Data_99m_WowheadCoords.lua").write_text(hdr + "\n".join(lines) + "\n")
(base/"review.txt").write_text("\n".join(sorted(review)) + "\n")
print(f"NPCs resolved      : {sum(1 for n in mounts if harvest.get(n,{}).get('status')=='ok')}/{len(mounts)}")
print(f"overrides written  : {applied}   (of which replace an existing coord: {changed})")
print(f"left for review    : {len(review)}")
