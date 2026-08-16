#!/usr/bin/env python3
"""Build Data/TravelNetwork.lua from the local travel-network source.

What this adds that we did not have: the PORTAL / SHIP / ZEPPELIN / TRAM layer.
Our flight data covers 4,054 taxi hops with measured seconds; this covers the
160 portal edges, 10 ship routes, 5 zeppelins and the Deeprun Tram, each with
real endpoint coordinates. Those legs were previously priced by assumption
(HUB_TRANSIT_MINUTES and friends) or not modelled as connections at all.

Parses by structure and REPORTS its coverage, because the first flight-time
extractor matched an assumed field order and silently captured a third of the
data. Any parser here prints captured-vs-present so a shortfall is visible.
"""
import re
import pathlib
import sys

SRC = pathlib.Path.home() / "Downloads/Mapzeroth/Mapzeroth_Data.lua"
OUT = pathlib.Path(__file__).resolve().parent.parent / "Data/TravelNetwork.lua"

# Seconds. Only used where the source states no cost of its own.
#
# These are ASSUMPTIONS and are labelled as such in the emitted file, so the
# time model can keep telling the truth about which of its numbers are measured.
DEFAULT_SECONDS = {
    "portal": 15,    # click, load screen, walk out
    "walk": 30,      # a short connecting walk inside a hub
    "tram": 90,      # the Deeprun Tram round is fixed and famously slow
    "ship": 120,     # matches the one stated ship cost in the source
    "zeppelin": 120,
    # NOT ZERO. These are normally priced from the real distance between the two
    # endpoints; these values are only the fallback when a coordinate lookup
    # fails. A zero here becomes a free edge in a shortest-path search, which is
    # teleportation the router will gladly chain across the world.
    "flight": 60,    # a short taxi hop, if distance cannot be measured
    "fly": 45,       # player self-flight over a modest gap
}


def lua_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main():
    if not SRC.exists():
        sys.exit("source not found: %s" % SRC)
    t = SRC.read_text(encoding="utf-8", errors="replace")
    nodes_blob = t[t.index("ns.Nodes"):t.index("ns.Edges")]
    edges_blob = t[t.index("ns.Edges"):]
    map_blob = t[t.index("ns.MapToTraversal"):] if "ns.MapToTraversal" in t else ""

    # ---- nodes: traversalGroup -> KEY = { name=, mapID=, x=, y=, faction= }
    nodes = {}
    group = None
    for line in nodes_blob.splitlines():
        g = re.match(r"\s{4}([A-Z][A-Z0-9_]+)\s*=\s*\{\s*$", line)
        if g:
            group = g.group(1)
            continue
        k = re.match(r"\s{8}([A-Z][A-Z0-9_]+)\s*=\s*\{", line)
        if k:
            cur = k.group(1)
            nodes[cur] = {"group": group}
            continue
        for field, pat in (("name", r'name\s*=\s*"([^"]*)"'),
                           ("faction", r'faction\s*=\s*"([^"]*)"'),
                           ("mapID", r"mapID\s*=\s*(\d+)"),
                           ("x", r"x\s*=\s*([\d.]+)"),
                           ("y", r"y\s*=\s*([\d.]+)")):
            m = re.search(pat, line)
            if m and nodes:
                last = cur if "cur" in dir() else None
                if last:
                    nodes[last][field] = m.group(1)

    present_nodes = len(re.findall(r"mapID\s*=", nodes_blob))
    usable = {k: v for k, v in nodes.items()
              if v.get("mapID") and v.get("x") and v.get("y")}

    # ---- edges: { from=, to=, method=, cost=? }
    # Split on the `from =` markers rather than matching balanced braces.
    #
    # The source writes edges as `}, {` on one line, so a `\{[^{}]*...\}` pattern
    # terminates at the wrong brace and captured 57 of 238. Anchoring on the
    # field that must start every record cannot miss one.
    edges = []
    marks = [m.start() for m in re.finditer(r'from\s*=\s*"', edges_blob)]
    for i, pos in enumerate(marks):
        end = marks[i + 1] if i + 1 < len(marks) else len(edges_blob)
        blk = edges_blob[pos:end]
        f = re.search(r'from\s*=\s*"([^"]+)"', blk)
        to = re.search(r'to\s*=\s*"([^"]+)"', blk)
        me = re.search(r'method\s*=\s*"([^"]+)"', blk)
        co = re.search(r"cost\s*=\s*([\d.]+)", blk)
        if f and to and me:
            edges.append((f.group(1), to.group(1), me.group(1),
                          int(float(co.group(1))) if co else None))
    present_edges = len(re.findall(r'from\s*=\s*"', edges_blob))

    # ---- mapID -> traversal group, for "can I even get there" checks
    m2t = re.findall(r"\[(\d+)\]\s*=\s*\"([A-Z0-9_]+)\"", map_blob)

    stated = sum(1 for e in edges if e[3] is not None)
    kept = [e for e in edges if e[0] in usable and e[1] in usable]

    print("  nodes present       : %d" % present_nodes)
    print("  nodes parsed        : %d" % len(nodes))
    print("  nodes usable (map+xy): %d" % len(usable))
    print("  edges present       : %d" % present_edges)
    print("  edges parsed        : %d" % len(edges))
    print("  edges with both ends: %d" % len(kept))
    print("  edges w/ stated cost: %d (rest use a labelled default)" % stated)
    print("  mapID -> group      : %d" % len(m2t))

    out = [
        "-- MasterMounts: the portal / ship / zeppelin / tram travel network.",
        "--",
        "-- Complements Data/FlightSeconds.lua. That file holds MEASURED taxi",
        "-- durations; this one holds the connections those flights cannot make --",
        "-- portals, boats, zeppelins and the Deeprun Tram -- with real endpoint",
        "-- coordinates, so a leg can be routed to a place rather than estimated",
        "-- as a flat hub charge.",
        "--",
        "-- %d nodes, %d edges. %d edges state their own duration; the rest take a"
        % (len(usable), len(kept), stated),
        "-- per-method default from MM.TravelDefaultSeconds, which is ASSUMED and",
        "-- labelled so, so the time model keeps reporting measured vs assumed",
        "-- honestly rather than laundering a guess as data.",
        "--",
        "-- Generated by tools/extract_travel_network.py. Do not hand-edit.",
        "local _, MM = ...",
        "",
        "MM.TravelDefaultSeconds = {",
    ]
    for k in sorted(DEFAULT_SECONDS):
        out.append('\t["%s"]=%d,' % (k, DEFAULT_SECONDS[k]))
    out += ["}", "", "MM.TravelNodes = {"]
    for key in sorted(usable):
        n = usable[key]
        bits = ['name="%s"' % lua_escape(n.get("name", key)),
                "mapID=%s" % n["mapID"],
                "x=%s" % n["x"], "y=%s" % n["y"]]
        if n.get("faction"):
            bits.append('faction="%s"' % n["faction"])
        if n.get("group"):
            bits.append('group="%s"' % n["group"])
        out.append('\t["%s"]={%s},' % (key, ",".join(bits)))
    out += ["}", "", "MM.TravelEdges = {"]
    for f, to, me, co in kept:
        cost = ',cost=%d' % co if co is not None else ""
        out.append('\t{from="%s",to="%s",method="%s"%s},' % (f, to, me, cost))
    out += ["}", "", "MM.MapTraversalGroup = {"]
    for mid, grp in m2t:
        out.append('\t[%s]="%s",' % (mid, grp))
    out.append("}")

    OUT.write_text("\n".join(out) + "\n")
    print("  wrote %s  %.0f KB" % (OUT.name, OUT.stat().st_size / 1024))


if __name__ == "__main__":
    main()
