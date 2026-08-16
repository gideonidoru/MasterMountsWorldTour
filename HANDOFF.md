# Master Mounts – World Tour — handoff

**Read this first, then `Data/_source/ORDER.txt` and `tools/audit.py`.**

## Where things stand

- **1.1.15 is published on CurseForge**, tagged `v1.1.15` at `6e07ed4`. It shipped
  on a clean gate: **193 passed, 7 degraded, 0 failed**, `/mm release` *shippable*.
- **1.2.0 is published on CurseForge**, tagged `v1.2.0` at `96a0c8e`. It shipped
  on a clean gate: **217 passed, 9 degraded, 0 failed** of 226, scorecard
  **96.3/100**, *shippable*, on client 12.1.0 build 69299. The tested copy was
  verified **byte for byte against the artifact** before the tag went on, after
  three earlier reports turned out to describe a build that was not the tip.
  **Do that check rather than trusting a timestamp.** It is the first release
  whose zip contains `LICENSE`; every 1.1.x download was a distribution without
  the notice the MIT licence requires be included in all copies.
- **Working version is 1.2.1, unreleased and untagged.** So far it carries the
  hardening pass that followed 1.2.0: the id export and the saved report no
  longer sit unbounded in saved variables (~140 KB per account, shed once on
  upgrade), the boss-kill debounce table is swept, and a seventeenth audit rule
  checks that a referenced texture is actually on disk -- including the sixteen
  button textures named only by interpolation, which no literal scan could see.
- **Why 1.2.0 is a minor rather than a patch:** attempt counts start moving for
  mounts that never counted, weight
  sliders that did nothing now re-chart, session totals shift onto the router's
  own travel model, and the interface is reskinned. Every saved chart is
  invalidated once on upgrade — the route signature gained six fields — so each
  character re-charts on its first login. Not 2.0: nothing in saved variables
  breaks, and a stale chart simply fails to match and is rebuilt.
- **The Modern theme artwork is not ours.** Everything under `Media/Modern/` --
  44 files, 7.8 MB -- is byte-identical to `Vaultloom/Assets/` by **Legijaone**,
  and is used **with that author's permission**. Recorded here because the
  overlap looks alarming when found cold: all 44 files match exactly, Vaultloom
  ships no LICENSE, and their copies predate ours. `NOTICE` scopes the MIT grant
  around it and ships in the download beside `LICENSE`; `## X-Credits` carries
  the attribution. Do not relicense, redistribute separately, or let a media
  cleanup treat it as ours.
- Where the repo is and what `dist/` is for: see **Where things live** below.

## What 1.1.15 fixed, and what it taught

**Map pins draw.** `UI/MapPins.lua` is now a `MapCanvasDataProvider` registered on
`WorldMapFrame`, acquiring pins from the canvas and handing each one normalised
0–1 coordinates through `SetPosition`. Blizzard owns placement, zoom, scaling and
culling; there is no offset arithmetic left for the world map. The minimap half has
no provider available, so it positions pins itself following HereBeDragons'
`drawMinimapPin`, measuring each map's east/south axes at runtime the way
`Nav/Arrow.lua` does rather than assuming which world axis points north.

**The pins were never only a drawing bug.** `indexLocations` read
`patrolWaypoints` and `zone` and stopped there, so it never saw **`spawns`** — 137
records, 649 points, already in the shipped build and already read by `Router.lua`
and `RareAlert.lua`. Every Midnight rare keeps its location there while its `zone`
carries a name and no coordinate. Zul'Aman went 6 → 16 places once the index read
it. **Check every field that holds the answer before concluding the consumer is
wrong.**

Pins are now **one per place, not one per mount** — 1236 points sit on 572 places,
because a Trading Post kiosk is shared by 103 mounts and would otherwise stack 105
invisible frames.

**The release blocker was never a regression.** `Adding to the plan from any pane`
sat at ~3.6 s for four builds. `Planner:Add`/`Remove` are a table insert and
remove, but each fires `MM_PLAN_CHANGED`, and Router rebuilds while a route is
active — two edits, two full builds, none of it visible at the call site.
`BUILD_BOUND` already existed for exactly this and the check simply was not in it.

Worth keeping: **`BuildSync` is ~1650 ms after a plan edit and ~55 ms otherwise**,
and both are correct. `RunBuild` restores `chartRank` from the stored chart only
while `stored.sig == sig`, and reading that chart is what skips the O(n²) travel
scan. A plan edit changes the signature, so the chart is stale and the scan runs.
The speed check never edits the plan, so it has only ever timed the cached path.

## The router build contract

`Build` returns a STATUS, never a count -- the count is not knowable at the
moment an asynchronous build is requested.

| call | when to use it |
|---|---|
| `Build(force)` | fire and forget. Returns `current` / `started` / `queued` / `running` / `completed`. |
| `BuildSync(force)` | you need the answer on the next line. Drains the running build **and** any replacement queued behind it. Returns `stops, ok` — a failed build leaves the PREVIOUS route standing, so the count alone cannot tell you whether it is fresh. |
| `AfterBuild(force, fn)` | you can wait. `fn(stops, ok)` runs when the route has landed. Registers BEFORE requesting, because a small plan can finish inside its first slice. |
| `Warm()` | settle the route once so several report sections describe the same one. |

`MM_ROUTE_BUILT` fires exactly once for the final valid build and never for an
obsolete one. `MM_ROUTE_ADVANCED` means only that the current goal moved.

**A build is published in one piece.** `RunBuild` assembles into a stage and
`R.Publish` installs route, unrouted, deferred, the goal index, totals,
`baseOrder`, `builtSignature`, `hereDebug`, the saved chart, the route index and
the session's planned count together, as its last statement. A build that throws
never reaches it, so the last good route is still standing -- and a superseded
build returns without publishing, because its order is already known to be
wrong. Helpers take the state they operate on (`R.Measure(S)`, `R.Reindex(S)`,
`R.SaveChart(sig, S)` ...) and default to the live router, so a build cannot
reach past its stage by accident.

Two signatures, deliberately: `R.builtSignature` describes the route on screen
and is written only by `Publish`; a private `activeBuildSignature` describes the
build in flight. Failure and supersession clear only the second.

**A failure hands over any queued replacement** rather than dropping it. The
queued request is for a different plan -- its signature moved, which is why it
was queued -- so honouring it is not retrying the thing that broke, and waiters
stay queued for it exactly as they do when a build is superseded.

## Travel invalidation

One signal, `MM.TravelChanged(scope, why)`, with three scopes:

- **`cooldown`** — prices moved, options did not. Journey answers are dropped;
  the route order is left alone.
- **`capability`** — what the character can press changed. Journey answers go,
  the graph stays.
- **`topology`** — the map changed. The graph itself is rebuilt.

Each layer subscribes and forgets only what it owns. The route signature carries
`MM.TravelFingerprint()` -- a fingerprint of the usable teleports and their
destinations plus the flight-point counts, keyed on the teleport snapshot's own
identity -- so a stored chart cannot outlive the capabilities it was ordered
around, and a reload does not invalidate it the way a counter would.

## Rules that are not negotiable

- **Never invent data** — coordinates, drop rates, prices, quest or spell ids. Read them
  from the client, DB2 (`wago.tools/db2/<Table>/csv`), HandyNotes, or leave the gap.
- **`/Applications/World of Warcraft/` is read-only.** Logs may be read. Mark deploys.
- Edit `Data/_source/*.lua` + `ORDER.txt`, **never** flat `Data/Mounts.lua`.
- **`unmeasurableGate` is how a record admits a requirement nothing can ask
  about** -- a Brawler's Guild rank, a follower's rank -- exactly as
  `noLocationReason` does for a place. It is a sentence, not a boolean, it is
  listed in `/mm known` so it cannot become a comment that only satisfies a
  checker, and it is NOT a way to silence a gate that could be modelled.
- Gates before any release: `python3 tools/audit.py` (**29 rules**), `luac -p` on every
  file, `tools/rebuild_data.sh` must print **IDENTICAL**. Every rule must read 0
  **except** `file-level forward calls`, which reports exactly one hit inside
  `HandyNotes/Libs/AceAddon-3.0/` — the reference copy in the project folder, which
  the audit globs and which never ships. Anything under `UI/`, `Nav/` or the root is real.
- **A clean `/mm report` from Mark IS the release gate.** Audit/luac/IDENTICAL pass
  happily on code that hangs.
- **"Push" means the zip to CurseForge, never git.** Keep git current always, without
  asking. Tags mark real releases only; bump the version *immediately after* a release
  ships so pasted reports identify their build.
- Shipped comments must be safe for strangers: never name or quote Mark, no "the user",
  no gendered pronouns, must not read as AI-generated.
- Use **absolute paths** for every file edit. `cd` persists between tool calls and has
  twice put edits into the release repo instead of the source.
- Assert an anchor is **unique** before replacing on it — a non-unique anchor once put a
  widget in the wrong function and crashed the options panel.
- Verify a new build rule by **injecting a fault and watching it fire**. A rule reporting
  zero proves nothing until you have seen it report one. The tenth rule was wrong
  **three times** before it was right and reported a clean zero on the bug it was
  written for; only injection found that.
- **Some faults are runtime-shaped and no static rule can see them.** Whether a
  window's native chrome is fully collected depends on the template it inherits,
  so that is asserted in `Tests.lua` against a real frame, and mirrored offline
  in `chrome.lua`. Reach for the release gate or a harness when the property
  lives in the widget tree rather than in the text of the file.
- **Three themes, and only the active one ever gets looked at.** Modern, Blizzard
  and ElvUI reach the same control by different routes -- Modern draws its own
  close and hides the native one, Blizzard restores template art it never hid,
  ElvUI hides template art and then relies on the native button anyway. A change
  to shared code can be correct on the theme in front of you and broken on the
  other two, which is how an invisible-but-clickable close button shipped. The
  release gate now walks all three; keep it that way when adding chrome.
- **A kind no theme names renders as nothing.** The columns, wells and cards are
  frames the addon creates, with no template art to fall back on, so a skin
  function that does not handle a kind leaves it blank rather than plain. Native
  controls are the opposite case -- leaving tabs, checkboxes, edit boxes and
  scroll bars to their own art IS the Blizzard theme. Rule 25 tells the two
  apart by reporting only styling written for a kind that cannot be reached.
- **The calendar lists a holiday on EVERY day it covers, as `HOLIDAY ONGOING`.**
  It does not emit markers only on the start/end Tuesdays -- a comment in
  `Availability.lua` claimed it did, and the Timewalking scan was built on that
  claim. `/mm events` dumps the month with sequence types and is what disproved
  it. Because ONGOING entries persist, "is there a marker in the past 7 days" is
  never the question; the NEWEST marker decides, and an `END` means the week is
  over. Read the dump before trusting any calendar reasoning here.
- **An atlas is not a texture path.** `GetTexture()` on an atlas-backed texture
  returns the whole SHEET, so feeding that back through `SetTexture` drops the
  atlas and draws every icon in the file. Use `rememberTexture` to record a
  look without changing it; `modernTexture` is for genuine replacement only.
  Rule 26 reports the round-trip. It is invisible on file-backed art, which is
  why five call sites carried it for months.
- **A currency that returns a value is not thereby the right currency.** Id 3130
  was picked for Midnight's Delver's Journey rank because it answered while the
  other candidates read 0 of 0 -- but an unstarted track reads zero PRECISELY
  because it has not been started. It is The War Within's season 2 delve
  renown, so a character holding last expansion's rank 10 satisfied a gate it
  had never begun. Check an id against the CLIENT'S OWN NAME for it (`/mm
  lookup`), never against whether it has data. `/mm report` now lists ids whose
  client name shares no word with ours.
- **Renown ids are minted per season and go stale on purpose.** Delver's Journey
  and Preyseeker's Journey both carry a season-scoped track, so a gate written
  against last season's id passes for anyone who ranked that one up. Revisit
  every such condition at a season rollover -- the id changing is expected, not
  a defect. Rule 28 catches a rollover that updated some records and missed
  others by reporting one named track measured as two different ids.
- **A NEW CHECK CAN BREAK THE RELEASE GATE.** Two checks referenced `MM.Data`,
  a namespace nothing defines, and threw in the client -- the gate's own
  verdict went to "not shippable" because of the tests, not the addon. The
  `unresolved MM.*` rule waved it through: an unknown MODULE was the one case
  it skipped. It now reports that, which is the strongest signal it has. Run
  the audit after writing a check, not only after changing shipped code.
- **"You are already here" must not promote work this visit cannot finish.**
  `shortWork` measures the VISIT, deliberately: a one-in-a-thousand rare has a
  huge total but each visit is a whole attempt that might succeed. An
  accumulation is different -- a thousand more Vile Essence cannot complete
  today however lucky you are. A tier fast-path was short-circuiting the visit
  measurement for everything at FIELD or below, which is how two Zul'Aman
  treasures reached positions 3 and 5 with 13-day estimates.
- **`SetConditionAmount` matches BY NAME, and the flat file resolves it at build
  time.** So a renamed condition prices nothing, the shipped addon never runs
  the call, and no in-client check can ever see the failure -- the miss only
  surfaced two reports later as a contribution gap. `tools/flatten_data.sh` now
  refuses to install a build where any price landed on nothing. That is the
  only layer that can see it.
- **The FIRST record for a name is canonical; later ones become altSources.** A
  bare Trading Post stub for Soaring Meaderbee therefore outranked the detailed
  War Within record, and the real price sat in an alternate source nothing
  reads. Check for an earlier duplicate before concluding a record is unpriced.

## Where things live

- **`tools/` and `HANDOFF.md` are now in the repo too**, synced from source
  rather than from `dist/` because they are not shipped. They spent the whole
  project unversioned on one disk.
- **This folder is the source of truth and is NOT a git repository.** The
  git-backed release repo is `~/Downloads/MasterMountsWorldTour-release`
  (`github.com/gideonidoru/MasterMountsWorldTour`). `tools/sync_repo.sh`
  rebuilds `dist/` and rsyncs it there; commits and pushes happen in the repo.
- **`dist/` is generated output.** Never edit it. `tools/build_dist.sh` starts
  with `rm -rf dist`, copies exactly what the .toc names plus `Media/` wholesale,
  and asserts the two agree in both directions. An asset outside `Media/` and
  outside the .toc would be deleted from the repo by the next sync -- that is
  why `README`, `LICENSE` and `CHANGELOG.md` are excluded by name.
- `Data/_source/` and `tools/` never ship.

## Future work: the layered data files

`Data/_source/` is 164 files, most of them override layers named for the session
that produced them (`Data_99zq_AttCoords`, `Data_99zzS_LastFour`). Load order is
significant and lives in `ORDER.txt`.

Normalising them into per-expansion files with a single override layer would be
a real improvement in readability. **It is not a mechanical move.** `AddMounts`
is first-wins and `OverrideMount` is last-wins, so collapsing layers changes
which value survives; `Data_15_Patch121` must precede `Data_13_GapFill` for
exactly that reason. Any such pass has to keep provenance -- each file's header
says where its data came from, which is what makes a wrong value traceable --
and must end with `verify_flatten` printing IDENTICAL against the pre-existing
flat file. Do it deliberately, with the flattener as the oracle, or not at all.

## Outstanding

- **Only 824 of 1329 obtainable records carry an `itemID` (62%).** This is the highest
  -leverage gap left. `IDResolver.lua` says in its own comment that 128 records could be
  located if we knew who stocked them, and merchant matching goes through
  `MM.ItemToMount`, which only exists where a record has an itemID. It is also why
  `tools/extract_handynotes_mounts.py` reports 34 unmatched items, including the ones
  that teach **Void-Corrupted Hex Eagle**, **Witherbark Warbear Mother**,
  **Void-Touched Snapdragon** and **Insatiable Shredclaw** — the four Midnight records
  that still cannot pin. MCL holds 595 candidate itemIDs;
  `C_MountJournal.GetMountFromItem` maps them authoritatively.
  `tools/RareLootHarvest.lua` + `RareLootResolve.lua` are the precedent: a dev-only
  candidate list, resolved once in-game, baked down to shipped rows.
- **`gapfill.lua` and `gapfill2.lua` sit unreviewed in the project root** (dev scratch,
  not shipped). ~900 values that PASSED client validation: 444 spellID, 181 dropRate,
  99 coords from MCL; 211 spellID, 130 coords, 33 npc_id from MountCollector. Nothing
  has been applied.
- **A plan edit costs ~1.65 s while a route is active** — real, felt when clicking [+]
  mid-route, and not a test artefact. Making the re-chart incremental is Router surgery;
  measure before attempting.
- 33 journal mounts uncatalogued; 16 of our records match no journal entry (10 carry no
  spellID, so only the name can match — check spelling before assuming absence).
- Two gaps only a player can close, both self-closing and both still open: **open the
  Trading Post once** this month, and **talk to any flight master once** (0 zones
  learned; 12 goals have no flight point).

## The lesson these sessions keep teaching

Measure instead of reasoning, and be specific about what you measured.

Three separate times this session a confident diagnosis was wrong and the
measurement was one command away: the pin index was right all along and the field
it never read was the bug; the plan-edit cost was blamed on the rebuild until a
three-way split inside the handler named it; and `chartRank` was read backwards as
the expensive path when it is the cheap one.

The corollary, learned twice more: **two copies of one rule is how the second one
drifts.** The rare alert deferred a secure attribute and never flushed it because
the arrow's flush lived somewhere else. The FIXES section computed its own
"slowest check" without the exemption the self-test applied, so one run reported
both a clean self-test and something to look at. Both now have one implementation
and one owner.
