#!/usr/bin/env python3
"""Replace assumed 1% drop rates with observed ones.

Every rate here carries its sample: 222/99271 is a measurement, 3/12 is a
rumour, and the addon should be able to tell them apart. Anything below a
minimum sample is left at the assumption rather than swapped for a number that
merely looks more precise.

THE SELECTION RULE, stated because it was not before.

A mount can drop from several sources. The first pass took whichever source
Wowhead happened to list FIRST -- Grand Black War Mammoth was recorded as
576/69331 from Archavon while Emalon, Koralon, Toravon and Doomwalker, another
202,000 observed kills, were discarded. That is not a rule, it is an accident
of ordering, and it silently understated the sample by 4x.

The rule now: SUM every source Wowhead reports for that item. Total observed
drops over total observed kills. Rows carrying a negative count are Wowhead's
"no data" sentinel and are excluded from both halves rather than added in.
`sources` records how many were summed, so a one-source number and a
five-source number are distinguishable afterwards.
"""
import json, pathlib, re

MIN_SAMPLE = 200   # below this, one lucky streak moves the number several-fold

base = pathlib.Path(__file__).parent
todo = {d["item"]: d["mount"] for d in json.loads((base/"droprate_todo.json").read_text())}
rows = json.loads((base/"droprate_results.json").read_text())

def esc(s): return s.replace("\\","\\\\").replace('"','\\"')
lines, skipped, applied = [], [], 0
for r in rows:
    mount = todo.get(r["item"])
    if not mount: continue
    if r.get("status") != "ok":
        skipped.append(f'{mount[:34]:<34} {r.get("status")}')
        continue
    # 0% and 100% are not drop rates -- they mean the item is not a random drop
    # from that source at all (a guaranteed hand-in, or mis-attributed loot).
    # Writing either would tell the planner something false and confident.
    #
    # NEAR-100% is the same statement. Void-Scarred Windrider reports 278 of
    # 279, which is not "a 99.6% chance" -- it is a guaranteed drop with one
    # odd observation, and recording it as a chance invites the planner to
    # model repeat attempts at something that never needs a second one.
    #
    # NEGATIVE counts come back too -- Wowhead reported -2 of 51,619 for one
    # item and -1 of 24 for another. Whatever that means upstream, it is not a
    # rate, and "count == 0" did not catch it.
    if r["count"] <= 0 or r["count"] / r["outof"] >= 0.99:
        skipped.append(f'{mount[:34]:<34} implausible rate ({r["count"]}/{r["outof"]})')
        continue
    if r["outof"] < MIN_SAMPLE:
        skipped.append(f'{mount[:34]:<34} sample too small ({r["count"]}/{r["outof"]})')
        continue
    pct = round(100.0 * r["count"] / r["outof"], 3)
    src = r.get("sources")
    lines.append(
        f'MM.OverrideMount("{esc(mount)}", {{ dropRate = {pct}, '
        f'dropObserved = {{ count = {r["count"]}, outOf = {r["outof"]}'
        + (f', sources = {src}' if src else '')
        + f' }} }}) -- item {r["item"]}')
    applied += 1

hdr = ("-- MasterMounts: observed drop rates, from Wowhead's reported counts.\n"
       "--\n"
       "-- These records were ranked on an assumed 1%, which is not a measurement\n"
       "-- and was wrong in BOTH directions -- Abyss Worm is 0.22%, others 2.5%.\n"
       "-- A 4x error in either direction reorders the plan, so this changed the\n"
       "-- advice and not just the totals.\n"
       "--\n"
       "-- `dropObserved` keeps the sample with the rate. 222/99271 is a\n"
       "-- measurement; 3/12 is a rumour that happens to divide. Anything under\n"
       f"-- {MIN_SAMPLE} observations is left at the assumption rather than dressed up.\n"
       "--\n"
       "-- Every source Wowhead reports for an item is SUMMED -- `sources` says\n"
       "-- how many. The first pass took whichever source was listed first, so\n"
       "-- Grand Black War Mammoth was 576/69331 from Archavon alone while four\n"
       "-- other bosses and 202,000 further kills went unread.\n"
       "--\n"
       "-- Rates move: these are rolling observations, not constants, and a\n"
       "-- re-run will not reproduce an older file exactly.\n"
       "local _, MM = ...\n\n")
(base/"Data_99u_DropRates.lua").write_text(hdr + "\n".join(lines) + "\n")
(base/"droprate_skipped.txt").write_text("\n".join(sorted(skipped)) + "\n")
print(f"applied : {applied}")
print(f"skipped : {len(skipped)}")
