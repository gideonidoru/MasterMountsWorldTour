# Verification tools

Master Mounts' database is authored with NAMES and resolves IDs from the
running client. These scripts guard that pipeline. They are verification
oracles only — **none of them imports another addon's data.**

| tool | checks against | run |
|---|---|---|
| `verify_ids.sh` | Wowhead (`spell=<id>&xml`, title parse) | `tools/verify_ids.sh` |
| `xcheck_client.lua` | the player's own client export (**authoritative**) | `lua tools/xcheck_client.lua` |
| `xcheck_mcl.lua` | a third-party addon's data, read-only | `lua tools/xcheck_mcl.lua` |

Direction matters: all three check **ID → name**, which is the safe direction.
A wrong ID silently maps a mount onto a *different* mount at load time
(`spellID` builds `MM.DBBySpell`); a wrong name merely fails to match.

`xcheck_client.lua` reads the SavedVariables path directly — edit the path at
the top if the account or install location differs.

## Results as of 2026-08-04
- vs client: **116 agree, 0 disagree**, 12 not in the journal
- vs Wowhead: 115 verified, 9 removed as wrong, 2 benign (`Summon X` naming)
- vs MCL: **49 overlap, 0 conflicts**

Three independent sources agree on every spellID we ship.

---

## Build: flattening the database

The database is authored as ~33 layered files in `Data/_source/` — per-expansion
sources plus override layers that patch them. The addon ships **one generated
file** instead.

```sh
tools/rebuild_data.sh                         # build (safe: temp file, parse check, then move)
# NEVER `lua tools/flatten_data.lua > Data/Mounts.lua` -- the shell truncates the
# target before lua runs, so a flattener error leaves the database EMPTY and silent.
lua tools/verify_flatten.lua Data/Mounts.lua   # prove it matches the sources
```

`verify_flatten` loads both stacks into separate namespaces and deep-compares
every canonical record in both directions, so neither a dropped field nor an
invented one survives. **Never ship a regenerated `Mounts.lua` that has not
passed it.**

### Things that will bite you

- **Load order is in `Data/_source/ORDER.txt`, not alphabetical.** `AddMounts` is
  first-wins, and `Data_15_Patch121` must precede `Data_13_GapFill` or 18 of the
  12.1 mounts lose to one-line stubs.
- **The flattener deliberately does not create a global `MM`.** A global would
  hide a data file that forgot `local _, MM = ...` — the bug that silently killed
  `Data_85` and `Data_86` (1,032 fills) until the release pass caught it.
- **Nothing in the data layer may depend on the player.** `ResolveFactionVariants`
  runs at runtime from `Core.lua`, so `altSources` and `factionOverlay` pass
  through untouched. If anything ever moves to load time, flattening starts
  baking one character's answers into everyone's copy.
- Output is chunked into 300-record `AddMounts` calls. We test-compile on Lua 5.5;
  WoW runs 5.1, with tighter per-function parser limits.

To edit data: change the file in `Data/_source/`, rebuild, verify.

---

## The static audit

```sh
python3 tools/audit.py              # 14 rules over everything the .toc loads
python3 tools/audit.py --selftest   # inject known faults, require them caught
```

Every rule must report **0** except `file-level forward calls`, which reports
exactly one hit inside `HandyNotes/Libs/AceAddon-3.0/` — the reference copy in
the project folder, which the audit globs and which never ships. Anything under
`UI/`, `Nav/` or the root is real.

**A new rule is not finished until you have watched it fire.** Inject a fault,
see it reported, remove it, see the clean zero. A rule that has only ever
reported zero is indistinguishable from one that cannot report anything, and
this has been wrong three times.

Three of the rules are worth knowing about because they read scope rather than
lines:

- **`build, then read the route`** finds an asynchronous `Build()` followed by a
  read of `route` / `totals` / `unrouted` / `deferred` / the goal index. It works
  on **function extents**, not a fixed window, so it catches a read separated
  from the build by helper declarations, and a build wrapped in
  `pcall(function() ... end)` is attributed to the function that wrote it. A read
  inside a callback is in its own function and is therefore not a hit — which is
  what makes `AfterBuild` the correct shape without needing an exception. A
  `BuildSync`, `AfterBuild`, `IsBuilding`, `Warm` or `BUILD_CURRENT` check ends
  the scan: those all mean the build has landed.
- **`build's return used as a count`** finds the return of an asynchronous
  `Build()` compared to a number or printed with `%d`. It reads the raw line for
  the `%d` case, because `strip()` blanks string literals before the rules see
  them.
- **`README record count drift`** compares the figure the README states against
  the records in the flattened database, so that number is verified rather than
  maintained.

`-- audit-allow` on a line exempts it, and is meant to be rare: the only
legitimate use so far is a check that deliberately reads mid-build state to
assert it is safe.
