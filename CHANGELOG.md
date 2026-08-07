# Changelog

## 1.1.10 — 2026-08-07

Attempt tracking, which turned out not to work at all on Midnight, and three
things the route was pointing at wrongly.

**Farming you do now registers**

- **Rares count again.** The combat-log path is Blizzard-only on 12.0, and the
  replacement written at the time — a per-record tracking quest — was never
  populated: **not one record in the database carried one**, so both pollers
  built around it had never fired. Killing a rare had recorded nothing for
  months, and `Attempts: 0 recorded` read as "you haven't farmed anything" when
  it meant "nothing here can be counted". `GetLootSourceInfo` replaces it: it
  hands back the GUID behind each loot slot, and a creature GUID carries the
  same creature id the tracker was already keyed on. **123 of 207** drop and
  rare goals can be matched this way; the other 84 are world drops with no
  single creature behind them.
- **Paragon caches register and advance.** Fifteen goals recorded nothing.
  `hasRewardPending` flips `true → false` when you open the cache, and that edge
  *is* the completion — consumed, bar reset, nothing more to do there today. The
  router's advance rule also fired only on a `DAILY`/`WEEKLY` lockout, and
  paragon records carry no such field, so even a recorded attempt would have
  left the route sitting still.
- **`/mm gaps` now prints what can and cannot mark a goal attempted** on your
  client, with the counts — rather than leaving it to be discovered by someone
  wondering why their farming never registers. The 21 chest goals still record
  nothing, and that is stated rather than hidden.

**The route points at the right place**

- **The Grand Hunt moves.** It runs in one of the four Dragonflight zones and
  rotates; the record named Ohn'ahran Plains with a fixed coordinate, which is
  right about a quarter of the time. The live map POI carries both the zone and
  the point. Completing one now takes it off the plan until the weekly reset —
  learned from the turn-in and the client's own reset timer, with **no quest id
  written down**.
- **Twelve treasures point at the actual chest** rather than a zone centre.
  Absence proves nothing here — a missing POI can mean looted, undiscovered,
  filtered off, or a zone not loaded — so this only ever improves a location and
  never gates, hides or completes a goal. Nine of the twenty-one are
  deliberately left alone, each with its reason recorded.

**Two copies of the addon**

- **An old folder left beside the current one now says so**, in chat at login,
  in the report header, and as a self-test check. It presents as three separate
  bugs — the celebration printing twice, two plan windows in two different
  styles, and a plan that appears to rewrite itself — and every one of them
  looks like a defect in this addon.

## 1.1.9 — 2026-08-07

Everything here came from one player testing 1.1.8 inside instances, and it is
the tail of the same 12.0 change: **secret values**.

- **`UnitName` is secret inside instances.** Reported as three distinct throws
  at once — `NAME_PLATE_UNIT_ADDED`, `UPDATE_MOUSEOVER_UNIT` and
  `PLAYER_TARGET_CHANGED` — which are the three events that reach
  `IDResolver.ObserveUnit`. 1.1.8 guarded the vignette observer and left this
  one four lines above it untouched: the third time that miss was made by
  fixing the site that was reported rather than the class.
- **A calendar title throws on a COMPARISON, not a conversion.**
  `ev.title ~= ""` is enough, reported as *"attempt to compare field 'title' (a
  secret string value)"*. It was then used as a table key, which would have
  failed again a line later.
- **The sweep, rather than a fifth report.** Every remaining read of a
  client-supplied string now goes through the same guard — quest titles in
  `Callings`, which have `:find()` called on them, and all five
  `GetBindLocation` reads across `Teleports`, `Travel` and `Diagnostics`, where
  the value is both a table key and an argument to a function that lowercases
  it. Neither had been reported.

Losing these costs almost nothing: the npc id comes from the GUID and is
unaffected, so rare alerts still match, and an event that cannot be named
simply joins no keyword matching.

`FIXES IN THIS BUILD` is what found the last three. It reported
`CHECK  Handler errors this session — 3 distinct` and named the events, which
named the sites.

## 1.1.8 — released

The first release with players on it. Everything below came from two of them
and from re-grading against the client's own data, and almost all of it is the
same shape: something that was wrong in a way the addon could not see.

**Six defects reported from outside, five of which repeated forever**

- **1,124 errors from one nil.** Death Gate, Zen Pilgrimage, Astral Recall,
  every mage portal and all 76 dungeon teleports are stored as `spell`, not
  `item`. The arrow's action button read `item` only and called
  `GetItemIconByID(nil)` twenty times a second. It offers the **spell** now —
  which is what a player wanted to click — and falls back to the arrow when a
  hop is neither. The nil never even reached the idempotence guard: that
  returns early only when the button is already shown, and a button that never
  shows fails it forever.
- **Every boss kill threw.** 12.0 makes `encounterName` a *secret value*.
  Comparing it is allowed; `encounterName:lower()` is not. Attempt counting now
  degrades, says so once, and keys its debounce on a readable name.
- **`nil failed:` named nothing** because `message` was not a variable in that
  function. It names the event now, and prints once per distinct problem
  instead of once per occurrence — a game event repeats, so one throwing
  handler used to bury the addon's own output for the session.
- **Every Wowhead link click was a hard error.** Blizzard's StaticPopup rewrite
  renamed `editBox` to `EditBox`. All four spellings accepted.
- **Route builds hit "script ran too long".** The yield sat *outside* the loop
  that costs the time — it handed the frame back between stops, while a single
  stop runs one graph search per candidate. Much worse for a new player: our
  own router model measures a character with no teleports taking fifteen hops
  where a geared one takes two, and the yielding was tuned against the cheap
  case.
- **The zone popup opened the whole collection.** Its rows were plain frames,
  so clicks fell through — the row under the cursor named the mount and the
  player still had to type its name. They are buttons now: left-click opens
  that mount, right-click goes to Wowhead.

**"It told me to go collect a mount I can't buy"**

- **Seven vendors checked a reputation and never said so.** The evaluator was
  never the bug — `Wild Goretusk` simply had no reputation condition, so its
  only requirement was a currency any max-level character has piles of and it
  ranked as "just go buy it". Found by reading `Mount.db2`'s `SourceText_lang`,
  which is the mount journal's own blurb and carries vendor, zone, faction *and
  standing*, and cost. We had been reading the name out of that file and
  discarding the rest of the line.
- **An item cost asked whether you had any, not how many.** `evalItem` compared
  `> 0` and threw the amount away, so 1 of 25 Miscellaneous Mechanica satisfied
  the Asset Advocator. Sixty conditions want more than one — every Alterac
  Valley mount needs 15 Marks of Honor, and a single Mark answered for all
  fifteen. `MATERIAL` rows had no evaluator at all and printed "Unknown
  requirement" 105 times.

**Data that was wrong in ways a counter read as fine**

- **Fifty gold prices added.** "Prices: 0 missing" was true and misleading: the
  gap only inspects VENDOR, CURRENCY and TIMEWALKING, and most gold-priced
  mounts are filed under REP. The counter hit zero while fifty mounts had no
  cost at all. Base prices, from the client — `Cenarion War Hippogryph` prints
  "1600 (2000 base)" on the mount pages against the client's 2000, and the
  `Lightforged Warframe` confirms it backwards.
- **Forty-eight goals pointed at the exact middle of their zone.** 50/50 is
  what a coordinate looks like when nobody knew, and it is *worse* than having
  none: a zone-only record is handled honestly everywhere, while a placeholder
  passes every check that asks whether an x exists rather than whether it means
  anything. Stripped at the end of the data build, with the zone kept.
- **The Nether-Swept Drake was in the wrong water.** We said Oceanic Vortex
  pools; a field report puts it in open water at Slayer's Rise, and carries a
  checkable tell — open water there grants fishing skill and the vortex pools
  do not.
- **Five collectibles named and counted** — Crackling Shard, Love Token,
  Noblegarden Chocolate, Merry Supplies, Abyssal Fragment. A prose quantity is
  a fact the addon cannot act on: no "27 / 270", no cost in the estimate.
- **`Alunira` disagreed with itself**: source and notes both said guaranteed,
  `dropRate` said 10 — which is the shard count.
- **Duplicated costs collapsed structurally.** `MATERIAL` keeps its id in
  `itemID` while `ITEM` and `CURRENCY` use `id`, so `Mimiron's Jumpjets`
  required all three booster parts twice. Normalisation now runs *last*; it had
  been called from the middle of the layer stack with nineteen layers landing
  after it.

**Performance**

- The vignette observer walked all 1,608 records on every minimap tick, to fill
  a field with thirty-five possible slots, and had no already-seen guard.
  Indexed once, entries removed as filled.

**New**

- **`/mm fixes`**, and a `FIXES IN THIS BUILD` section at the end of the
  report. Twelve probes, every one measuring live state and carrying what the
  broken version looked like. Four of the six reported defects were invisible
  from inside the report; this is the section that would have caught them.

**Reported from live play after the first fix round**

- **12.0 secret values, swept rather than patched one at a time.** Midnight
  hands a tainted addon a *secret value* where a client string used to be, and
  any string operation on one throws — including `~= ""`, which needs no
  concatenation at all. This arrived as four separate reports: every boss kill,
  then delve combat, then three more events at once, then a calendar title.
  Fixing the reported *site* each time meant the next report was already
  written. There is now one guard, `Util.ReadableString`, and **sixteen call
  sites across ten files** go through it — unit names, vignette names, POI names
  and descriptions, encounter names, calendar titles, quest titles and every
  hearthstone bind. Two of those had not been reported; they are the same shape
  as the ones that were.
- Every site **degrades instead of throwing**: a vignette we cannot name teaches
  no npc id (the id comes from the GUID and is unaffected, so rare alerts still
  match), an event we cannot name joins no keyword matching.
- **`[+]` in the planner's left pane did nothing.** Four attempts blamed a
  different part of the child-`Button` machinery — the handler, the frame level,
  the click registration, the scroll box's anchors — and the handlers turned out
  to be identical to the two panes that worked. The machinery is gone: the glyph
  is a `FontString` on the row, the region that responds is **the glyph's own
  rect**, so what you see and what you can press are one rectangle by
  construction, and it acts on `OnMouseDown` so it never needs a press and a
  release to land on one recycled frame.
- The left pane also described its own rectangle differently from every other
  list in the addon — two anchors on the same edge plus `SetWidth`, where
  Collection and the plan pane both anchor opposite corners.
- **The `[+]`/`[-]` tooltip said "Add / remove from farm plan" everywhere.** That
  describes the control, not the click in front of you. `mmTooltip` already
  existed, was already set on the plan pane's button, and nothing ever read it.

**New**

- **`/mm fixes`**, and a `FIXES IN THIS BUILD` section at the end of the report.
  Thirteen probes, every one measuring live state and carrying what the broken
  version looked like. Four of the six defects reported by players were
  invisible from inside the report; this is the section that catches them — and
  it is what named the last three secret-value sites.
- **`/mm rowprobe`** reports what the planner's left pane actually is: frame
  levels, geometry, whether the scripts exist, and whether a click would add
  anything at all.

**Self-test**

- Two checks failed for reasons unrelated to what they tested, and one passed
  *vacuously* on an empty plan — `cap 8 costs 0.0% more travel (0 → 0 min)`.
  Zero minutes against zero minutes is not evidence, and going green on it was
  the more dangerous of the two: one held the release gate shut for no reason,
  the other would have waved a real regression through.

## 1.1.5 — released

**Data**

Every requirement in the database now carries an id the client can resolve —
condition ids 351 → 0, reputation ids 151 → 252. Named only, a requirement is a
string: the client cannot be asked whether it is met, so the planner falls back
to an assumption for the whole mount. Sourced from the client's own DB2 tables
rather than from a guide, read with a real CSV parser — an earlier pass split on
commas by hand, and the name column contains quoted commas, so it matched
nothing and looked exactly like "the data is not there".

- **Crafting reagents for 50 of 57 crafted mounts**, including every Protoform
  Synthesis mount — the set `Crafting.lua` named as unpriceable without a player
  opening a profession window for each recipe in turn. Three joins: the spell
  that creates the teaching item, that spell's reagents, and their names. A
  harvested recipe still wins where they disagree, because this is what the
  RECIPE costs and the profession window knows what it costs YOU.
- **Prices**: 68 unpriced purchases → 0. Gold prices cross-checked against two
  independent sources; 27 of 29 matched exactly, and where they differed the
  client's own table won.
- **Locations**: 16 unexplained → 0. The rest carry a written reason.
- **All four remaining puzzle chains** now carry their steps.
- Covenant requirements are answerable at last. 53 conditions read
  `{ type = "QUEST", name = "Covenant: Night Fae" }` — no quest of that name
  exists, so no lookup was ever going to find one, and they were filed as a
  platform limit. `C_Covenants` answers it outright.

**Corrections**

- **57 mounts were charged their cost twice.** Fifteen listed one token as both
  an ITEM and a CURRENCY condition; forty-two named one reputation under two
  spellings. A record with two requirements looks entirely normal, which is why
  they lasted.
- **Eleven mounts nobody can obtain were being planned, costed and routed.**
  A mount that cannot be obtained is not a long grind — it is not a goal.
- **Promoting a faction variant discarded every id the data layers applied**,
  on one faction only: correct on the client you test with, broken on the one
  you do not, identical in the data file.
- The Dapple Gray sent players to the wrong city, the Vorquins claimed to be
  Blood Elf heritage mounts when they are the Dracthyr racials, the Deathtusk
  Felboar was catalogued as a rare drop and is a vendor mount, and two records
  named mounts that do not exist.

**Rare alerts**

- The alert can now be heard through a muted client. The Master channel escapes
  the SFX slider and nothing else, so the master volume, the global sound switch
  and the play-while-alt-tabbed setting are lifted for the length of the clip and
  handed straight back — with the originals written to disk first, so a crash
  mid-alert restores them at the next login rather than leaving the game
  permanently loud.
- A murloc, and it leads the list.

**Chat**

- Three lines that talked without saying anything are gone. A line earns its
  place if you asked for it, if something happened you would want to know and
  cannot see, or if something failed where silence and success look identical.

**Contributions**

- `/mm contribute import` has never applied anything. The export writes the
  display name and the import looked it up in a table keyed by the lowercased
  one, so every line resolved to "unknown mount". The round-trip test passed the
  whole time, because an unrecognised name is a no-op exactly like an untouched
  placeholder.


## 1.1.0 — superseded by 1.1.5, never shipped separately

**Titan Panel**

- Completes the LibDataBroker contract Titan actually reads. Titan turns every
  LDB data source into a plugin of its own, so a second, native registration
  would have put Master Mounts in your bar twice — the fix was to say more, not
  to register again.
- `label` added, so a display addon can show the name and the value separately
  rather than falling back to the object's id and rendering "MasterMounts".
- `tocname` added, and this one was a real defect: Titan resolves a plugin's
  category, version and notes with `GetAddOnMetadata(tocname or objectName)`.
  The object is named `MasterMounts`, the folder is `MasterMountsWorldTour`, so
  every lookup returned nil and the plugin would have appeared uncategorised and
  versionless.
- `X-Category: Information` in the toc, which is the field Titan reads for
  category. `Category-enUS` is Blizzard's and Titan never looks at it.
- A self-test now verifies the broker against the live client: the type a
  display addon can map, the four fields it needs, both handlers, and that
  `tocname` names an addon this client actually has whose version matches
  `MM.VERSION`. The folder-name mismatch above is the same shape that once broke
  four textures silently, and it is checkable.

Also benefits Bazooka, ChocolateBar and ElvUI datatexts, which read the same
object.

## 1.0.0 — 2026-08-05

First release.

**Travel**

- Chains every mode into one route — fly, taxi, portal, boat, zeppelin, tram,
  hearthstone and dungeon teleport — instead of comparing them one at a time.
  A leg that looks worse than flying on its own is often the first hop of the
  fastest chain there is.
- 4,068 measured flight-path durations. Observed trip times, not distance over
  speed: a flight follows a scripted path with turns and a takeoff, so a
  straight-line guess is wrong in both directions.
- 564 portal, ship, zeppelin and dungeon-door connections, faction-gated, with
  one-way routes kept one-way — a return trip that does not exist is not a
  saving.
- 76 dungeon and raid teleports. Every one is checked against your spellbook
  before it is offered, because a teleport you have not earned that shortens
  your route on paper is worse than not modelling it at all.
- Where it cannot route, it says which of the three faults it hit: no way on to
  the network, no way off at the far end, or genuinely no path. Four causes
  needing four fixes are not distinguished by a dash.

**Planning**

- 1,608 mounts catalogued with source, drop rate, lockout and prerequisites
- Builds a route, not a list — ordered by travel time and effort, pricing every
  portal, ship, flight path and teleport item you own
- Groups mounts that share a stop, so five Island Expedition mounts are one visit
- **Pick the time you actually have** and the plan is constrained to fit it
- Faction, class, profession, reputation and lockout gates all checked, so it
  won't send you somewhere nothing can happen

**Rares**

- Watches the rares that drop mounts you're still missing — not every rare in
  the game, just yours
- Triggered off vignette data, so you hear about it while you can still get there
- Shows the model, the drop, the distance and a target button; once per spawn
- Rares you already have the mount from never fire

**Trust**

- Every estimate says whether it was measured or assumed
- Unknowns are costed pessimistically, so a guess can never outrank real work
- `/mm report` shows everything it knows and everything it doesn't
- `/mm contribute` exports the gaps a player standing in the right place could
  actually answer, and imports someone else's back

**Also**

- Warband-aware reputation, currency and professions
- Attempts tracked account-wide, with no implied pity timer
- Nav arrow, map pins, rare alerts, TomTom and MountsRarity support
