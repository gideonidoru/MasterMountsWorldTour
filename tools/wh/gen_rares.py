#!/usr/bin/env python3
"""Populate rare spawn data from HandyNotes.

Two things come out of this:
  1. Coordinates for mounts that had none.
  2. `poolRares` -- the full list of rares that can drop a mount. RareAlert
     already reads this field but nothing populated it, so a mount dropping
     from five rares only ever alerted on one of them.

Every spawn point is kept. A rare that patrols or spawns in several places is
the normal case here, not an exception, and collapsing it to the first point is
how a player gets routed to the wrong end of a zone.
"""
import re, json, pathlib
rares = json.loads(pathlib.Path("handynotes_rares.json").read_text())
FLAT  = pathlib.Path.home()/"Downloads/MasterMountsWorldTour/Data/Mounts.lua"

cur=None; recs={}
for l in FLAT.read_text(encoding="utf-8",errors="replace").splitlines():
    m=re.match(r'\s*name\s*=\s*"((?:[^"\\]|\\.)*)",',l)
    if m and (len(l)-len(l.lstrip()))<=2: cur=m.group(1); recs[cur]={"cat":None,"xy":False}
    elif cur:
        c=re.match(r'\s*category\s*=\s*"(\w+)",',l)
        if c: recs[cur]["cat"]=c.group(1)
        if re.match(r'\s*x\s*=\s*[\d.]+,',l): recs[cur]["xy"]=True

def norm(s): return re.sub(r'^(reins of the|reins of|the)\s+','',s.lower().strip()).strip()
bylabel={}
for r in rares:
    for mo in r["mounts"]:
        bylabel.setdefault(norm(mo["label"]), []).append(r)

def esc(s): return s.replace("\\","\\\\").replace('"','\\"')
coord_lines, pool_lines = [], []
for mount, meta in sorted(recs.items()):
    rs = bylabel.get(norm(mount))
    if not rs: continue
    named = [r for r in rs if r.get("name")]
    # all spawn points, across every rare that drops it
    pts = []
    for r in rs:
        for (x, y) in r["spawns"]:
            t = (r["mapID"], x, y)
            if t not in pts: pts.append(t)
    if not meta["xy"] and pts:
        mp, x, y = pts[0]
        coord_lines.append(
            f'MM.OverrideMount("{esc(mount)}", {{ zone = {{ mapID = {mp}, x = {x}, y = {y} }} }}) '
            f'-- {named[0]["name"] if named else "rare"} (handynotes)')
    if len(named) > 1 or len(pts) > 1:
        names = ", ".join(f'"{esc(r["name"])}"' for r in named)
        sp = ", ".join(f'{{ mapID = {mp}, x = {x}, y = {y} }}' for mp, x, y in pts)
        pool_lines.append(
            f'MM.OverrideMount("{esc(mount)}", {{ sharedZonePool = true, '
            f'poolRares = {{ {names} }}, spawns = {{ {sp} }} }}) -- {len(pts)} point(s)')

hdr = ("-- MasterMounts: rare spawn points, extracted from HandyNotes.\n"
       "-- `poolRares` lists EVERY rare that can drop the mount -- RareAlert already\n"
       "-- read this field but nothing populated it, so a mount dropping from five\n"
       "-- rares only ever alerted on one. `spawns` keeps every point, because a\n"
       "-- rare that patrols or spawns in several places is the normal case and\n"
       "-- collapsing it to the first is how a player ends up at the wrong end of a\n"
       "-- zone. The router does not yet choose the nearest of these.\n"
       "local _, MM = ...\n\n")
out = pathlib.Path("Data_99n_RareSpawns.lua")
out.write_text(hdr + "\n".join(coord_lines + [""] + pool_lines) + "\n")
print(f"coordinate fills : {len(coord_lines)}")
print(f"pool/spawn rows  : {len(pool_lines)}")
print(f"total spawn points recorded : {sum(l.count('mapID') for l in pool_lines)}")
