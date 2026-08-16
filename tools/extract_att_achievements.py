#!/usr/bin/env python3
"""Find achievement ids for mounts whose record names one only in prose.

35 ACHIEVEMENT records name their achievement in a sentence and nothing can
read progress from them, so each is ranked on a flat six-hour meta assumption.
The local collectible database states the relationship structurally:

    ach(4156, { r=2, g = { mnt(68187, { itemID=49096 }) } })

A mount NESTED inside an achievement container is rewarded by it. That is a
containment relationship, not a text pattern, so this walks the braces and
keeps a stack of open achievement scopes rather than matching nearby digits --
a regex would happily pair a mount with whichever id happened to sit closest.

Retail data (db/Standard) wins; the per-expansion databases are consulted only
where retail is silent, and the source is reported per hit so a Classic-only
id cannot quietly pass for a retail one.
"""
import re
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ATT = pathlib.Path.home() / "Downloads/AllTheThings/db"
OUT = ROOT / "Data/_source/Data_99zi_AttAchievements.lua"

DUMP = r'''
local MM={}
MM.AddMounts=function(t) MM._all=MM._all or {}; for _,r in ipairs(t) do MM._all[#MM._all+1]=r end end
MM.AddVendorLocations=function() end
MM.OverrideMount=function() end
local c=load(io.open("Data/Mounts.lua"):read("a"),"f","t"); pcall(c,"MM",MM)
for _,r in ipairs(MM._all or {}) do
  if r.category=="ACHIEVEMENT" then
    local modelled=false
    for _,cond in ipairs(r.conditions or {}) do
      if cond.type=="ACHIEVEMENT" then modelled=true break end
    end
    if not modelled and (r.spellID or r.itemID) then
      print((r.name or "?") .. "\t" .. tostring(r.spellID or 0)
        .. "\t" .. tostring(r.itemID or 0))
    end
  end
end
'''

ACH_OPEN = re.compile(r"ach\((\d+)\s*,\s*\{")
MNT = re.compile(r"mnt\((\d+)")
# A mount can also be listed by its ITEM inside the achievement scope, and many
# of our records carry an itemID where they carry no spellID.
MNT_ITEM = re.compile(r"itemID\s*=\s*(\d+)")
ITEM = re.compile(r"i\((\d+)")


def scan(text):
    """spellID -> achievement id, by brace containment.

    Walks the text once holding a stack of (achID, depth). A mount seen while
    the stack is non-empty belongs to the achievement on top.
    """
    found = {}
    stack = []
    depth = 0
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            while stack and stack[-1][1] > depth:
                stack.pop()
        else:
            m = ACH_OPEN.match(text, i)
            if m:
                depth += 1                      # the brace this opened
                stack.append((int(m.group(1)), depth))
                i = m.end()
                continue
            m = MNT.match(text, i)
            if m and stack:
                found.setdefault(("s", int(m.group(1))), stack[-1][0])
                i = m.end()
                continue
            m = MNT_ITEM.match(text, i)
            if m and stack:
                found.setdefault(("i", int(m.group(1))), stack[-1][0])
                i = m.end()
                continue
            m = ITEM.match(text, i)
            if m and stack:
                found.setdefault(("i", int(m.group(1))), stack[-1][0])
                i = m.end()
                continue
        i += 1
    return found


def main():
    if not ATT.exists():
        sys.exit("collectible database not found: %s" % ATT)
    res = subprocess.run(["lua", "-e", DUMP], cwd=ROOT, capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit("could not read the database: " + res.stderr[:300])

    want = {}
    for line in res.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            name, spell, item = parts
            if spell != "0":
                want[("s", int(spell))] = name
            if item != "0":
                want[("i", int(item))] = name

    # Retail first, then the rest, so a Classic id can never overwrite a retail one.
    order = sorted(ATT.rglob("*.lua"),
                   key=lambda p: (0 if "Standard" in p.parts else 1, str(p)))
    hits, source = {}, {}
    for f in order:
        text = f.read_text(encoding="utf-8", errors="replace")
        if "mnt(" not in text:
            continue
        for key, ach in scan(text).items():
            name = want.get(key)
            if name and name not in hits:
                hits[name] = ach
                source[name] = f.parts[-3] if len(f.parts) > 2 else f.name

    names = sorted(set(want.values()))
    print("  records needing an achievement id : %d" % len(names))
    print("  found by containment              : %d" % len(hits))
    for nm in sorted(hits):
        print("     %-30s ach %-7d (%s)" % (nm[:30], hits[nm], source[nm]))
    missing = [n for n in names if n not in hits]
    print("  still unknown                     : %d" % len(missing))
    for m in sorted(missing)[:8]:
        print("     %s" % m)

    out = [
        "-- MasterMounts: achievement ids for mounts whose record named one only",
        "-- in prose, taken from the local collectible database by CONTAINMENT.",
        "--",
        "-- A mount nested inside an achievement scope is rewarded by it. That is",
        "-- a structural relationship rather than a text pattern, which is why the",
        "-- extractor walks braces and keeps a stack of open scopes: matching",
        "-- nearby digits would pair a mount with whichever id happened to sit",
        "-- closest in the file.",
        "--",
        "-- %d of %d resolved. Retail data wins; the per-expansion databases are"
        % (len(hits), len(names)),
        "-- consulted only where retail is silent.",
        "--",
        "-- Generated by tools/extract_att_achievements.py. Do not hand-edit.",
        "local _, MM = ...",
        "",
    ]
    for nm in sorted(hits):
        esc = nm.replace("\\", "\\\\").replace('"', '\\"')
        out.append('MM.OverrideMount("%s", { conditions = { '
                   '{ type = "ACHIEVEMENT", id = %d } } })  -- %s'
                   % (esc, hits[nm], source[nm]))
    OUT.write_text("\n".join(out) + "\n")
    print("  wrote %s" % OUT.name)


if __name__ == "__main__":
    main()
