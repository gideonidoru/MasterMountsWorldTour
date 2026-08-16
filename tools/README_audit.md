# Wowhead guide audit

Re-runnable check of our acquisition categories against Wowhead's
"Lord of the Reins" complete mount-collecting guide. Worth repeating after a
major patch, or whenever the guide's WIP sections get filled in.

## Steps

1. `curl` the guide, extract the BBCode body from the `printHtml("...")` payload.
2. Parse every `[table]` row into `itemID -> section`, deciding the section from
   the nearest preceding `[anchor=...]` (13 sections: vendor, rep, profs, achiev,
   calendar, quests, pvp, drops, argent, garrison, class, realmoney).
3. Resolve each item to the spell it teaches:
   `https://nether.wowhead.com/tooltip/item/<id>` returns JSON whose tooltip
   contains `/spell=<id>/<mount-name-slug>`. That slug is the mount's real name.
4. Dump our side with `lua tools/dump_db.lua` from the addon root.
5. Join on spellID, falling back to the normalised name slug.

## The one trap

`dump_db.lua` filters to CANONICAL records only:

    MM.DBBySpell[rec.spellID] == rec  or  MM.DBByName[rec.name:lower()] == rec

`MM.AddMounts` appends every record to `MM.DBList` but keeps only the first as
canonical, demoting later duplicates to `altSources`. Iterating `DBList` raw
double-counts 134 records and invents mismatches that do not exist in game —
it will tell you Ashes of Al'ar is a Timewalking mount when the canonical record
correctly has it as a Tempest Keep raid drop.

## Reading the result

A disagreement is not automatically an error. The guide buckets mounts by how a
collector browses them; we categorise by what the player actually has to do. An
achievement-gated vendor mount belongs under `achiev` in a browsing guide and
under `VENDOR` here. Read each one before changing anything.
