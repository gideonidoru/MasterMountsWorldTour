#!/usr/bin/env python3
"""Map EVERY mount to the NPC named in its source prose, using the built flat
file (well-formed) rather than a line scan of the layered sources -- that scan
misread multi-line records as having no coordinate.

Wowhead is authoritative: a mount whose source names a resolved NPC takes that
NPC's coordinates whether or not it already had some.
"""
import re, json, pathlib
from collections import defaultdict

FLAT = pathlib.Path.home()/"Downloads/MasterMountsWorldTour/Data/Mounts.lua"

PATTERNS = [
    re.compile(r"\b(?:Sold|Purchased|Bought)\s+by\s+([A-Z][\w'’\-]*(?:\s+[A-Z][\w'’\-]*){0,3})"),
    re.compile(r"\b(?:Dropped|Drops)\s+by\s+([A-Z][\w'’\-]*(?:\s+[A-Z][\w'’\-]*){0,3})"),
    re.compile(r"\bfrom\s+([A-Z][\w'’\-]*(?:\s+[A-Z][\w'’\-]*){0,3})\s+(?:in|at|on)\b"),
]
BAD = {"the","a","an","mythic","heroic","normal","raid","dungeon","quest","achievement",
       "trading","post","vendor","world","boss","island","expedition","event","darkmoon",
       "faire","black","market","auction","house"}

def candidate(src):
    for p in PATTERNS:
        m = p.search(src or "")
        if not m: continue
        nm = m.group(1).strip().rstrip('.,')
        t = nm.split()
        if not t or len(t) > 4: continue
        if any(w.lower() in BAD for w in t): continue
        return nm
    return None

# walk the flat file, collecting one record per top-level mount
recs, cur = {}, None
for line in FLAT.read_text(encoding="utf-8", errors="replace").splitlines():
    ind = len(line) - len(line.lstrip())
    m = re.match(r'\s*name\s*=\s*"((?:[^"\\]|\\.)*)",', line)
    if m and ind <= 2:
        cur = m.group(1); recs[cur] = {"mount": cur, "source": "", "faction": None, "hasxy": False}
    elif cur:
        s = re.match(r'\s*source\s*=\s*"((?:[^"\\]|\\.)*)",', line)
        if s: recs[cur]["source"] = s.group(1)
        f = re.match(r'\s*faction\s*=\s*"(\w+)",', line)
        if f: recs[cur]["faction"] = f.group(1)
        if re.match(r'\s*x\s*=\s*[\d.]+,', line): recs[cur]["hasxy"] = True

out = []
for r in recs.values():
    npc = candidate(r["source"])
    if npc: out.append({**r, "npc": npc})

by = defaultdict(list)
for r in out: by[r["npc"]].append(r)
print(f"mounts in flat build       : {len(recs)}")
print(f"mounts naming an NPC       : {len(out)}")
print(f"  of those, already have xy: {sum(1 for r in out if r['hasxy'])}")
print(f"unique NPCs                : {len(by)}")
pathlib.Path("worklist2.json").write_text(json.dumps(out, indent=1, ensure_ascii=False))
pathlib.Path("names2.json").write_text(json.dumps(sorted(by), ensure_ascii=False))
new = sorted(set(by) - set(json.loads(pathlib.Path("names.json").read_text())))
print(f"NPCs not in the first pass : {len(new)}")
print("  ", new[:12])
