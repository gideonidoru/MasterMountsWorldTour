#!/usr/bin/env python3
"""Extract rare NPCs, their spawn points and mount rewards from HandyNotes.

Node keys encode the position as two 4-digit halves scaled by 100:
    map.nodes[61636958]  ->  x 61.63, y 69.58
A `pois = {POI({a, b, c})}` list carries ADDITIONAL spawn points for rares that
patrol or spawn in several places -- we keep every one of them rather than
collapsing to the first, because "which one is it at right now" is the actual
question a player has.
"""
import re, json, pathlib
from collections import defaultdict

ROOT = pathlib.Path.home()/"Downloads"

def split_coord(n):
    s = str(int(n))
    if len(s) not in (7, 8): return None
    s = s.zfill(8)
    x, y = int(s[:4])/100, int(s[4:])/100
    if not (0 <= x <= 100 and 0 <= y <= 100): return None
    return round(x, 2), round(y, 2)

def block(text, start):
    """Return the {...} block beginning at the first '{' at/after start."""
    i = text.find('{', start)
    if i < 0: return None, start
    d = 0
    for j in range(i, len(text)):
        if text[j] == '{': d += 1
        elif text[j] == '}':
            d -= 1
            if d == 0: return text[i:j+1], j
    return None, start

rares = []
for addon in sorted(ROOT.glob("HandyNotes_*")):
    for zf in sorted(addon.rglob("zones/*.lua")):
        txt = zf.read_text(encoding="utf-8", errors="replace")
        maps = {m.group(1): int(m.group(2))
                for m in re.finditer(r'local\s+(\w+)\s*=\s*Map\(\{\s*id\s*=\s*(\d+)', txt)}
        if not maps: continue
        for nm in re.finditer(r'(\w+)\.nodes\[(\d+)\]\s*=\s*(Rare|NPC)\(', txt):
            var, coord, kind = nm.group(1), nm.group(2), nm.group(3)
            mapid = maps.get(var)
            if not mapid: continue
            pos = split_coord(coord)
            if not pos: continue
            body, end = block(txt, nm.end()-1)
            if not body: continue
            nid = re.search(r'\bid\s*=\s*(\d+)', body)
            label = re.search(r'\}\)\s*--\s*([^\n]+)', txt[end:end+120])
            spawns = [pos]
            for p in re.finditer(r'POI\(\{([\d,\s]+)\}', body):
                for c in re.findall(r'\d+', p.group(1)):
                    q = split_coord(c)
                    if q and q not in spawns: spawns.append(q)
            mounts = [{"item": int(a), "mountID": int(b), "label": c.strip()}
                      for a, b, c in re.findall(r'Mount\(\{\s*item\s*=\s*(\d+),\s*id\s*=\s*(\d+)\s*\}\)\s*,?\s*--\s*([^\n]+)', body)]
            rares.append({
                "addon": addon.name.replace("HandyNotes_", ""),
                "zone_file": zf.stem, "mapID": mapid,
                "npcID": int(nid.group(1)) if nid else None,
                "name": (label.group(1).strip() if label else None),
                "spawns": spawns, "mounts": mounts, "kind": kind})

multi = [r for r in rares if len(r["spawns"]) > 1]
withm = [r for r in rares if r["mounts"]]
print(f"rare/NPC nodes extracted : {len(rares)}")
print(f"  with >1 spawn point    : {len(multi)}  (max {max((len(r['spawns']) for r in rares), default=0)} points)")
print(f"  carrying a mount reward: {len(withm)}")
print(f"  named                  : {sum(1 for r in rares if r['name'])}")
print(f"  distinct maps          : {len({r['mapID'] for r in rares})}")
pathlib.Path("handynotes_rares.json").write_text(json.dumps(rares, ensure_ascii=False))
print("\nsample multi-spawn:")
for r in multi[:4]:
    print(f"  {str(r['name'])[:28]:<28} m{r['mapID']:<5} {len(r['spawns'])} spawns  {r['spawns'][:3]}")
print("\nsample mount reward:")
for r in withm[:4]:
    print(f"  {str(r['name'])[:26]:<26} m{r['mapID']:<5} {r['spawns'][0]}  -> {r['mounts'][0]['label'][:34]}")
