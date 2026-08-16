#!/usr/bin/env python3
"""Build Data/TransitLinks.lua from the local travel-graph source.

What this adds that we did not have: PORTALS, BOATS, ZEPPELINS AND DUNGEON
DOORS KEYED BY ZONE NAME, with a coordinate at both ends.

Our existing network (Data/TravelNetwork.lua) keys on opaque node keys and
covers 238 connections. This source states its links as
"Zone/floor x,y -x- Zone/floor x,y", which the addon can resolve directly --
it already turns 199 of 205 zone names into map ids -- so a link lands on a
real place instead of an internal identifier that may match nothing.

It is also the layer the router kept failing on. Tazavesh, the Sanctum of
Domination, Mechagon and the Forbidden Reach sub-zones were all "no path" or
"no node", and every one of them is stated here.

Parses by structure and REPORTS its coverage, because two earlier extractors
matched an assumed shape and silently captured a fraction of the file.
"""
import re
import pathlib
import sys

SRC = pathlib.Path.home() / "Downloads/ZygorGuidesViewer/Libs-Retail/LibRover-1.0"
MAPS = SRC / "data.lua"   # zone name + floor -> the real map id
OUT = pathlib.Path(__file__).resolve().parent.parent / "Data/TransitLinks.lua"

FILES = ("data_transit.lua", "data_dungeons.lua", "data_floorcrossings.lua")

# A node end, in ALL THREE forms the source actually writes.
#
# The first cut demanded "Zone/floor x,y" and dropped everything else, which
# quietly cost 257 links -- among them the dungeon ENTRANCES. "Silverpine
# Forest 44.75,67.79 -x- Shadowfang Keep 69.46,60.97" states no floor, so
# Shadowfang Keep kept its nine internal staircases and had no door from the
# world outside; it sat in the graph as an island, along with 68 other zones.
#
#   Zone/3 12.34,56.78     an explicit floor
#   Zone##862 12.34,56.78  an explicit map id, which wins outright
#   Zone 12.34,56.78       no floor stated, which MEANS floor 0
#
# A trailing "@name" DEFINES an anchor other links point at.
NODE = re.compile(
    r"^\s*([^/@<{|#]+?)\s*(?:/\s*(\d+)|##(\d+))?\s+([\d.]+)\s*,\s*([\d.]+)"
    r"\s*(?:@!?([A-Za-z0-9_]+))?")

# "-to- @org_tp_dst": the destination is a NAMED ANCHOR declared elsewhere.
#
# 218 links were written this way and every one was dropped -- which is to say
# the entire "click the portal to Orgrimmar / Stormwind / Bel'ameth" network,
# the busiest travel in the game. The anchors are ordinary node declarations
# ("Orgrimmar/1 57.10,89.81 @org_tp_dst"), so they are collected in a first
# pass and substituted in a second.
REF = re.compile(r"^\s*@!?([A-Za-z0-9_]+)")

# Seconds. Only where the source states no cost of its own.
#
# ASSUMPTIONS, labelled as such in the emitted file so the time model can keep
# reporting measured vs assumed honestly. NONE OF THEM IS ZERO: a zero here is
# a free edge in a shortest-path search, which is teleportation the router will
# gladly chain across the world.
# Keys are the SOURCE's own mode names, not names we thought it used. The first
# cut invented "BOAT" and "FLIGHT"; the file says SHIP and FLY, so every ship
# route and the Deeprun Tram fell through to the WALK default and 31 boats
# became 30-second strolls. A vocabulary you assume is a vocabulary you get
# wrong -- these were read out of the file.
DEFAULT_SECONDS = {
    "PORTAL": 15,     # click, load screen, walk out
    "SHIP": 120,
    "ZEPPELIN": 120,
    "TRAM": 90,
    "FLY": 45,        # a short self-flight across a gap
    "WALK": 30,       # a short connecting walk, a door, a floor change
}


def floor_map_index():
    """zone name -> {floor: mapID}, read from the source, not inferred.

    THE REASON FLOORS WERE DROPPED. A floor is a separate map with its own
    coordinate space, so a floor-5 pair read against the floor-0 map lands
    somewhere else entirely -- and 805 links were thrown away rather than
    carried wrongly. That was right at the time, because nothing here knew
    which map a floor WAS.

    It is stated: ["The Forbidden Reach"] = {[0]=2118, [1]=2107, [5]=2151, ...}.
    With the real id per floor the links can be carried exactly instead of
    approximately, and the ones that were dropped come back.
    """
    if not MAPS.exists():
        return {}
    text = MAPS.read_text(encoding="utf-8", errors="replace")
    body = text[text.index("data.MapIDsByName"):]
    out = {}
    for m in re.finditer(r'\["([^"]+)"\]\s*=\s*\{([^}]*)\}', body):
        floors = {int(f): int(i)
                  for f, i in re.findall(r"\[(\d+)\]\s*=\s*(\d+)", m.group(2))}
        if floors:
            out[m.group(1)] = floors
    return out


def lua_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def joined_strings(text):
    """Every quoted string, with Lua's `.." "` concatenations folded together.

    The source wraps long link definitions across lines with `..`; a per-line
    scan sees two halves of one record and matches neither.
    """
    text = re.sub(r'"\s*\.\.\s*(?:--[^\n]*\n\s*)?"', "", text)
    return re.findall(r'"((?:[^"\\]|\\.)*)"', text)


def parse_node(chunk, anchors=None):
    """One end of a link. Resolves an @anchor reference against `anchors`."""
    ref = REF.match(chunk)
    if ref:
        return dict(anchors[ref.group(1)]) if anchors and ref.group(1) in anchors else None
    m = NODE.match(chunk)
    if not m:
        return None
    return {
        "zone": m.group(1).strip(),
        # No floor stated means the zone's BASE floor -- which is not always 0.
        # The index runs [0]=333 for Zul'Aman but [1]=310 for Shadowfang Keep,
        # so assuming 0 dropped 38 dungeon entrances for want of a floor the
        # source never had. `floor_stated` records which case this is; the
        # lookup below picks the base floor when nothing was written.
        "floor": int(m.group(2)) if m.group(2) else 0,
        "floor_stated": m.group(2) is not None,
        # An explicit ##id is the map, and beats any floor lookup.
        "explicit_map": int(m.group(3)) if m.group(3) else None,
        "x": float(m.group(4)),
        "y": float(m.group(5)),
        "anchor": m.group(6),
    }


def collect_anchors(all_strings):
    """@name -> node. An anchor may be declared on a link line, so every end
    of every string is examined, not only the standalone declarations."""
    anchors = {}
    for s in all_strings:
        for part in re.split(r"\s+-(?:x|to)-\s+", s):
            n = parse_node(part)
            if n and n.get("anchor"):
                anchors[n["anchor"]] = n
    return anchors


def main():
    if not SRC.exists():
        sys.exit("source not found: %s" % SRC)

    floors = floor_map_index()
    print("  zones with a floor->map index: %d" % len(floors))

    # PASS ONE: every anchor in every file, before any link is resolved.
    # An anchor declared in data_transit is referenced from data_dungeons, so
    # this cannot be done per file.
    per_file = {}
    every_string = []
    for fname in FILES:
        p = SRC / fname
        if not p.exists():
            print("  %-24s MISSING" % fname)
            continue
        per_file[fname] = joined_strings(p.read_text(encoding="utf-8", errors="replace"))
        every_string += per_file[fname]
    anchors = collect_anchors(every_string)
    print("  named anchors declared        : %d" % len(anchors))

    links, seen = [], set()
    stats = {}
    unmapped = {}
    unresolved_refs = {}
    resolved_refs = 0
    for fname, strings in per_file.items():
        kept = skipped_floor = malformed = 0
        for s in strings:
            # `-x-` is bidirectional, `-to-` is one way. Both matter: a one-way
            # portal modelled as two-way invents a route home that does not
            # exist.
            oneway = " -to- " in s
            parts = re.split(r"\s+-(?:x|to)-\s+", s)
            if len(parts) != 2:
                continue
            a, b = parse_node(parts[0], anchors), parse_node(parts[1], anchors)
            if not (a and b):
                malformed += 1
                for part in parts:
                    r = REF.match(part)
                    if r and r.group(1) not in anchors:
                        unresolved_refs[r.group(1)] = True
                continue
            for part in parts:
                if REF.match(part):
                    resolved_refs += 1
            # EVERY FLOOR, each against its OWN map.
            #
            # A floor is a separate map with its own coordinate space, which is
            # why these were dropped: a floor-5 pair read against the floor-0
            # map lands somewhere else entirely. That was the right call while
            # nothing here knew which map a floor WAS.
            #
            # The source states it -- ["The Forbidden Reach"] = {[0]=2118,
            # [5]=2151, ...} -- so each end now resolves to the map that floor
            # actually is, and the links come back exact rather than dropped.
            # A link is still dropped if either floor has no id: carrying one
            # against the WRONG map is the thing worth avoiding, not carrying
            # it at all.
            # An explicit "##862" states the map outright and is not a guess to
            # be improved on; otherwise the floor index answers.
            for end in (a, b):
                idx = floors.get(end["zone"]) or {}
                if end.get("explicit_map"):
                    end["mapID"] = end["explicit_map"]
                elif end.get("floor_stated"):
                    end["mapID"] = idx.get(end["floor"])
                elif idx:
                    # Bare zone name -> its base floor, read from the index.
                    end["mapID"] = idx.get(0) or idx[min(idx)]
                else:
                    end["mapID"] = None
            if not a["mapID"] or not b["mapID"]:
                skipped_floor += 1
                for end in (a, b):
                    if not end["mapID"]:
                        unmapped["%s/%d" % (end["zone"], end["floor"])] = True
                continue
            # An explicit mode wins. Otherwise only the DECLARED dungeon-portal
            # marker counts -- matching the bare word "portal" also matched
            # titles like "Go through the portal", which turned ordinary doors
            # into portals and inflated the count to 495.
            mode = None
            mm = re.search(r"\{mode:([A-Za-z]+)\}", s)
            if mm and mm.group(1).upper() in DEFAULT_SECONDS:
                mode = mm.group(1).upper()
            elif "{autotype:portal_dungeon}" in s:
                mode = "PORTAL"
            if mode is None:
                mode = "WALK"
            fac = None
            fm = re.search(r"\{fac:([AHB])\}", s)
            if fm and fm.group(1) in ("A", "H"):
                fac = "Alliance" if fm.group(1) == "A" else "Horde"
            # 0,0 IS "INSIDE", NOT A PLACE.
            #
            # A dungeon interior end is written 0.00,0.00 -- a marker, not a
            # coordinate. Carried as a position it puts the node in the map's
            # top-left corner and every distance measured to it is wrong, in a
            # way that reads as a real number. Flag it so the addon treats that
            # end as "the instance" and never as somewhere to measure to.
            a["inside"] = (a["x"] == 0.0 and a["y"] == 0.0)
            b["inside"] = (b["x"] == 0.0 and b["y"] == 0.0)
            key = (a["zone"], round(a["x"], 2), round(a["y"], 2),
                   b["zone"], round(b["x"], 2), round(b["y"], 2), mode, fac)
            if key in seen:
                continue
            seen.add(key)
            links.append((a, b, mode, fac, oneway))
            kept += 1
        stats[fname] = (len(strings), kept, skipped_floor, malformed)

    for f, (total, kept, sf, bad) in stats.items():
        print("  %-24s %5d strings -> %4d links (%d unmapped floor, %d unparsed)"
              % (f, total, kept, sf, bad))
    if unmapped:
        print("  zone/floor pairs with no map id: %d (dropped)" % len(unmapped))
        for k in sorted(unmapped)[:5]:
            print("     %s" % k)
    print("  @anchor destinations resolved : %d" % resolved_refs)
    if unresolved_refs:
        # Named but never declared. Reported rather than guessed at.
        print("  @anchors referenced, never declared: %d (those links dropped)"
              % len(unresolved_refs))
        print("     %s" % ", ".join(sorted(unresolved_refs)))

    modes, zones, oneways, gated = {}, set(), 0, 0
    for a, b, mode, fac, ow in links:
        modes[mode] = modes.get(mode, 0) + 1
        zones.add(a["zone"])
        zones.add(b["zone"])
        oneways += 1 if ow else 0
        gated += 1 if fac else 0
    print("  total links         : %d" % len(links))
    print("  distinct zone names : %d" % len(zones))
    print("  one-way links       : %d" % oneways)
    print("  faction-gated links : %d" % gated)
    inside = sum(1 for a, b, _, _, _ in links if a["inside"] or b["inside"])
    print("  ends marked INSIDE  : %d (0,0 is a marker, not a coordinate)" % inside)
    print("  by mode             : %s"
          % ", ".join("%s %d" % (k, modes[k]) for k in sorted(modes)))

    out = [
        "-- MasterMounts: portals, boats, zeppelins and doors, by ZONE NAME.",
        "--",
        "-- Complements Data/TravelNetwork.lua. That file keys on internal node",
        "-- identifiers; this one states both ends as a zone name and a",
        "-- coordinate, which the addon already resolves to a map id -- so a link",
        "-- lands on a real place rather than an identifier that may match",
        "-- nothing on this client.",
        "--",
        "-- %d links across %d zones. %d are ONE WAY (modelling a one-way portal"
        % (len(links), len(zones), oneways),
        "-- as two-way invents a route home that does not exist) and %d are"
        % gated,
        "-- faction-gated.",
        "--",
        "-- EVERY floor is carried, each against its own map id. A floor is a",
        "-- separate map with its own coordinate space, so a floor-3 pair read",
        "-- against the floor-0 map lands somewhere else entirely -- which is why",
        "-- floors were once dropped wholesale. The source states the id per",
        "-- floor, so they are carried exactly instead of approximately.",
        "--",
        "-- A link whose zone names one map at each end may still be a REAL link:",
        "-- 45% of these join two floors of the same instance and read as a",
        "-- self-loop by name. They are internal stairs, not no-ops.",
        "--",
        "-- Durations in MM.TransitSeconds are ASSUMED and labelled so, so the",
        "-- time model keeps reporting measured vs assumed honestly. None is",
        "-- zero: a zero-cost edge is teleportation to a shortest-path search.",
        "--",
        "-- Generated by tools/extract_transit_links.py. Do not hand-edit.",
        "local _, MM = ...",
        "",
        "MM.TransitSeconds = {",
    ]
    for k in sorted(DEFAULT_SECONDS):
        out.append('\t["%s"]=%d,' % (k, DEFAULT_SECONDS[k]))
    out += ["}", "", "MM.TransitLinks = {"]
    for a, b, mode, fac, ow in sorted(
            links, key=lambda l: (l[0]["zone"], l[1]["zone"], l[2])):
        bits = [
            'a="%s"' % lua_escape(a["zone"]), "ax=%.2f" % a["x"], "ay=%.2f" % a["y"],
            'b="%s"' % lua_escape(b["zone"]), "bx=%.2f" % b["x"], "by=%.2f" % b["y"],
            'mode="%s"' % mode,
        ]
        if fac:
            bits.append('faction="%s"' % fac)
        if ow:
            bits.append("oneway=true")
        if a["inside"]:
            bits.append("ainside=true")
        if b["inside"]:
            bits.append("binside=true")
        bits.append("amap=%d" % a["mapID"])
        bits.append("bmap=%d" % b["mapID"])
        out.append("\t{%s}," % ",".join(bits))
    out.append("}")

    OUT.write_text("\n".join(out) + "\n")
    print("  wrote %s  %.0f KB" % (OUT.name, OUT.stat().st_size / 1024))


if __name__ == "__main__":
    main()
