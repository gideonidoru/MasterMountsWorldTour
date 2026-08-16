#!/usr/bin/env python3
"""Find mount records with no usable x,y and extract a candidate NPC name.

We only emit a candidate when the source prose names someone in a form we can
trust. A guess here becomes a coordinate, and a wrong coordinate is worse than
an empty one -- it looks answered.
"""
import re, json, pathlib, sys

SRC = pathlib.Path.home() / "Downloads/MasterMountsWorldTour/Data/_source"

# "Sold by X at/in/on ...", "Dropped by X in ...", "X drops ..."
PATTERNS = [
    re.compile(r"\b(?:Sold|Purchased|Bought)\s+by\s+([A-Z][\w'’\-]*(?:\s+[A-Z][\w'’\-]*){0,3})"),
    re.compile(r"\b(?:Dropped|Drops)\s+by\s+([A-Z][\w'’\-]*(?:\s+[A-Z][\w'’\-]*){0,3})"),
    re.compile(r"\bfrom\s+([A-Z][\w'’\-]*(?:\s+[A-Z][\w'’\-]*){0,3})\s+(?:in|at|on)\b"),
]
# words that mean we grabbed a place or a thing, not a person
BAD = {"the","a","an","mythic","heroic","normal","raid","dungeon","quest","achievement",
       "trading","post","vendor","world","boss","island","expedition","event","darkmoon",
       "faire","black","market","auction","house"}

def candidate(source):
    if not source: return None
    for p in PATTERNS:
        m = p.search(source)
        if m:
            nm = m.group(1).strip().rstrip('.,')
            toks = nm.split()
            if not toks: continue
            if any(t.lower() in BAD for t in toks): continue
            if len(toks) > 4: continue
            return nm
    return None

recs, missing = 0, []
for f in sorted(SRC.glob("*.lua")):
    text = f.read_text(encoding="utf-8", errors="replace")
    for line in text.splitlines():
        s = line.strip()
        if not s.startswith("{") or "name" not in s: continue
        nm = re.search(r'name\s*=\s*"((?:[^"\\]|\\.)*)"', s)
        if not nm: continue
        recs += 1
        # a record is located only if it has BOTH x and y inside a zone table
        z = re.search(r'zone\s*=\s*\{(.*?)\}', s)
        has_xy = bool(z and re.search(r'\bx\s*=\s*[\d.]+', z.group(1))
                        and re.search(r'\by\s*=\s*[\d.]+', z.group(1)))
        if has_xy: continue
        src = re.search(r'source\s*=\s*"((?:[^"\\]|\\.)*)"', s)
        srct = src.group(1) if src else ""
        cat = re.search(r'category\s*=\s*"(\w+)"', s)
        zname = re.search(r'name\s*=\s*"([^"]+)"', z.group(1)) if z else None
        missing.append({
            "mount": nm.group(1),
            "file": f.name,
            "category": cat.group(1) if cat else "?",
            "zone": zname.group(1) if zname else None,
            "source": srct,
            "npc": candidate(srct),
        })

with_npc = [m for m in missing if m["npc"]]
print(f"records scanned      : {recs}")
print(f"missing x,y          : {len(missing)}")
print(f"  with NPC candidate : {len(with_npc)}")
print(f"  no candidate       : {len(missing)-len(with_npc)}")
print()
from collections import Counter
print("by category:", dict(Counter(m['category'] for m in missing).most_common()))
print()
print("sample WITH candidate:")
for m in with_npc[:8]:
    print(f"  {m['npc']:<28} <- {m['mount'][:34]:<34} [{m['category']}]")
print()
print("sample WITHOUT candidate:")
for m in [x for x in missing if not x['npc']][:6]:
    print(f"  {m['mount'][:38]:<38} [{m['category']}] {m['source'][:60]}")

out = pathlib.Path.home()/"Downloads/MasterMountsWorldTour/tools/wh/worklist.json"
out.write_text(json.dumps(missing, indent=1, ensure_ascii=False))
print(f"\nwrote {out}")
