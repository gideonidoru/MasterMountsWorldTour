# Changelog

## 1.1.12 — 2026-08-07

- **A teleport name that disagreed with the client** — `Path of Proven Worth`
  shipped with an extra "the". Cosmetic on its own, since everything matches by
  spell id, but it is the same drift that produced a wrong id elsewhere.

- **Three more travel items**, with their requirements read from the client
  rather than remembered: the **Wormhole Centrifuge** (Draenor Engineering), the
  **Wormhole Generator: Quel'Thalas** (Midnight Engineering) and the **Personal
  Key to the Arcantina** (no profession at all). The method was validated against
  the three already shipped before being trusted — it reproduces Northrend at
  rank 40 and the Zandalar generator needing *Kul Tiran* Engineering, which is
  the one nobody would guess.
- **The Dalaran Hearthstone was missing.** It runs on its own cooldown, so it is
  a second free trip rather than another flavour of the first one. Found by
  walking every toy in the client through its spell — a toy's teleport lives in
  the spell, not the item's flavour text, which is why reading item text alone
  turned up almost nothing.

- **One dungeon teleport had never been offered to anyone.** The Algeth'ar
  Academy teleport shipped as spell `393272`, which in the client's own table is
  `[DNT] Eclipse Lake - WQ 01 - Ping - 3` — an internal test entry. So
  `IsPlayerSpell` was false for every player alive, nothing errored, nothing was
  missing from any list, and the route was simply longer than it needed to be. A
  wrong spell id fails silently and forever.
- **Six more dungeon teleports added**, read from the client rather than a
  third-party export that was eleven behind: Karazhan, Maisara Caverns, Den of
  Nalorakk, Murder Row, Temple of Sethraliss and Kings' Rest. Four others are
  deliberately left out — the travel network has no node for where they land, and
  a teleport aimed at a guess would win a route on a distance nobody measured.
- **Midnight and The War Within mage teleports**, both missing: `Teleport:
  Dornogal` and `Teleport: Silvermoon City`. Five client spells are called some
  variant of "Teleport: Silvermoon"; only one is a mage's, settled by asking
  which sit on the mage skill line rather than by taking the newest id.
- A check now asserts every dungeon teleport id names itself exactly as shipped,
  which is the shape that failure took.

- **The mage teleport list stopped at Dragonflight.** `Teleport: Dornogal` was
  missing, so a mage was routed the long way to everything in Khaz Algar while
  holding a thirty-second answer. Its spell id comes from the client's own
  SpellName table, not from memory. (A Midnight-era `Teleport: Silvermoon City`
  also exists and is *not* added yet — there are two Silvermoon maps and picking
  the wrong one would route people to the wrong city.)

- **A weekly event finished on one character stopped being offered on all of
  them.** The completion was stored account-wide, and it is the one thing it
  cannot be: a Grand Hunt's first run each week is per character — which is the
  entire premise of reading the banner, since the tier it shows is what *this*
  character would get. It lives on the character now. The old account-wide entry
  is left to expire rather than migrated: one entry across six characters cannot
  be split back into truth, and inventing an answer for five of them is worse
  than a stale week timing out.
- Two checks force a full synchronous build to verify build behaviour, and a
  synchronous build is about three seconds on a 90-stop plan against the 37 ms
  the chunked one reports. They are exempt from the per-check budget, and
  **named and measured in the report** rather than quietly skipped — an
  exemption nobody can see is how a real regression hides.

- **The self-test could run against a route that was still being built.**
  Slicing it across frames means it no longer sees one frozen snapshot, and an
  asynchronous build mutates the route between slices — which produced "101 of
  285 planned goals vanished" and a dozen "no route" degradations in a report
  taken while the router was resuming. The suite was right about what it saw;
  what it saw was a building site. It waits for the build now, up to three
  seconds, so a stuck one cannot swallow the report.
- **The banner was found and then not looked at.** A record names the four zones
  a Grand Hunt rotates between, which is right — but the banner announcing it
  sits on the map *above* them. The scan covered that map and the search did
  not, so the POI appeared in the report and was invisible to the only code that
  wanted it. Each gate now searches its declared zones plus whatever contains
  them, derived from the client.
- **Two checks opened by rebuilding a route they already had.** `BuildSync` does
  the whole job in one call — about 1.3 seconds on an 82-stop plan, against the
  35 ms the chunked build reports — and both of the suite's slowest checks
  started with one purely to have a route in hand, when the suite had already
  built one. Anything testing build *behaviour* still builds; this only stops
  fetching what is already there.
- **The check budget is calibrated rather than guessed.** 500 ms kept failing a
  check that demonstrably survives on the slowest machine available, while the
  one actually killed was doing seven re-plans. Two rounds of real optimisation
  moved it 1,184 ms to 1,033, which is the point at which shaving is chasing a
  number rather than a fault. The line is 1,200 ms: above what is known to
  survive, below what is known to die, and honestly a regression tripwire rather
  than a proof of safety.
- **The Grand Hunt reward tier is now actually read.** It is not in the POI's
  description — the client's own generated documentation gives `AreaPOIInfo` a
  `tooltipWidgetSet` and no reward field whatsoever, which is why a detector
  reading `description` could never have worked. The tier comes from the tooltip
  widgets, and those are read without naming a single widget type: the text sits
  behind a different call per type, so every visualization function is asked and
  whatever answers is kept. A table of type-to-function guesses would rot the
  first time Blizzard adds a type.
- A banner whose tooltip cannot be read now says "cannot tell" rather than
  "already taken" — unreadable is the same nothing as absent.
- **We were asking one of several POI getters.** A Grand Hunts banner sat on the
  Dragon Isles map with a timer and a reward line while `GetAreaPOIForMap` on
  that same map returned nothing in the same session. Every function the client
  exposes ending in `ForMap` is asked now, and the names are discovered rather
  than guessed — writing down a hoped-for name would have been the same mistake
  as inventing a quest id. The report says which getter produced what.

- **One self-test check re-planned seven times and was killed on slower
  hardware.** Applying a preset announces the change, and announcing it
  re-plans; the preset round-trip applied four presets plus a defaults probe,
  so it re-planned seven times for states nobody would ever see. None of that
  work is part of what it checks. It still runs the real `ApplyPreset` — testing
  a copy of it would test the copy — but is no longer allowed to tell the plan
  about settings that exist for one line.
- **The router model resolved a map for every mount you do not own, to fill a
  field it reads a dozen times.** Picking which goals to model asked "can the
  router place this" of roughly sixteen hundred records up front, when the only
  code that reads the answer stops as soon as it has enough candidates. Asking
  for two goals cost the same as asking for two hundred. It is answered on
  demand now, which makes `/mm routertest` itself markedly quicker.
- **The router-model check modelled the whole sample to prove a swap.** What it
  protects is that the model puts your route back after borrowing the plan, and
  that path does not care how many goals were borrowed — but a full run measured
  1,184 ms in one call, which is precisely what the watchdog kills. Two goals go
  through the identical swap and restore. It also refuses to pass when the model
  finds nothing to sample, because then no swap happened and there is nothing to
  conclude.
- **Every check is timed now, and a line is held under the slowest.** A check
  that outlasts the client blames whichever line the axe fell on, which is never
  the one that matters — this one blamed the event dispatcher. Slicing the suite
  cannot help, because a slice may only stop *between* checks. So the check
  names itself instead.

- **The real cause of "script ran too long" was one section, not thirty-three.**
  Chunking the report between sections shipped in 1.1.12 and did not fix it: the
  self-test alone is 2,635 ms in a single uninterrupted run on a fast machine,
  and the client's watchdog measures exactly that. The probe added in 1.1.12
  named it, which is what it was for.
- The 193 checks now run **a slice at a time**, capped per frame rather than per
  run — so no single execution grows past that cap however slow the machine or
  however many checks are added later. The checks themselves are unchanged and
  unaware of it.
- **The suite can no longer run inside itself, by any route.** Slicing it out
  of the report meant running it with no report "in progress" — and one check
  fires every diagnostic section to prove none is silent, while one of those
  sections re-runs the suite when no run has finished. A nested run never
  finishes before it asks again, so it asked forever. Every layer sat inside a
  pcall, so the client hung with an empty log and nothing to point at.
- That had been guarded twice already with flags naming a *context* — "not
  while a report builds", then "not while one is prepared" — and both times a
  new context appeared that the flag did not describe. It now asks the property
  that actually matters: is a run already in progress. The flag is cleared even
  if the run throws, because one that latched would hand back stale counts
  forever and look exactly like a healthy suite.
- **The recursion guard now covers both halves.** One check times the report by
  building one, and stood down only while a report was already building —
  which the new prepare phase is not, by that flag's reckoning. So it built a
  report, which ran the suite, which appended a second copy of every result.
  The report came back reading "282 passed of 297": more checks than exist, no
  failures, and nothing anywhere saying something was wrong.
- The summary now counts duplicate results and says so loudly. A suite that ran
  twice otherwise just looks like a bigger suite that passed.
- They also run **during the four-second pause the report already takes** to let
  asynchronous subsystems answer, and the section that prints them consumes the
  finished results instead of running everything a second time. `/mm test` still
  always runs fresh — answering "did my change take" from results gathered
  minutes ago would look identical and be worthless.
- **The Grand Hunt says whether it is worth the trip, not merely where it is.**
  Only the first hunt each week pays the bag that carries the mount, and the
  banner's own description names the bag on offer — so a description still
  advertising the Epic one is the strongest "go now" this event can produce,
  and it reads the same from any continent. The status line says so.
- Whether the hunt is a task quest underneath turned out not to matter, and a
  briefly-widened quest scan has been put back to three zones. Casting a wider
  net on a theory costs every player the scan and answers a question the banner
  had already answered.
- Removed a comment asserting that a zone you are not standing in returns only
  permanent landmarks. It was concluded from one scan that showed no hunt,
  which does not distinguish "cannot be read remotely" from "none was running"
  — and the same scan returned Iskaara and Loamm from another continent.


- **`/mm report` died with "script ran too long" on slower hardware.** All 33
  sections ran in one uninterrupted execution, and the client's watchdog
  measures a single run rather than total work — so the fix is to stop doing it
  all at once, not to do less of it. Sections are independent, so the report
  breathes between them now and assembles over a few frames. An extra moment to
  build is invisible; tripping the watchdog produced nothing at all, which is
  the worst possible time for a diagnostic to fail.
- **One broken section no longer hides the other thirty-two.** A section that
  threw took the whole report with it and returned an error string instead —
  losing exactly the context needed to work out why. Each is wrapped, and a
  failed one says so in place.
- The freeze check was measuring the total, which stopped being the number that
  matters the moment this was chunked. It holds a line under the slowest
  *single* section now, and a second check catches a builder that quietly stops
  chunking.

- **The arrow and the plan could point at different mounts.** Reported from
  play: the guide led with Island Expeditions while the arrow said queue for
  Timewalking. Reading where you were heading also WROTE the resume anchor, so
  drawing a panel — or running `/mm report` — re-stamped it. The anchor is
  account-wide and the index is per-character, so an alt inherited a place its
  own plan never had. A read is a read now, and the anchor moves when the route
  moves.
- **A rebuilt plan could still lead with the old plan's goal.** When the anchor
  was missing or its mount was gone, the anchor was dropped and the index was
  left pointing into a route that no longer existed. Clearing the plan and
  rebuilding therefore led with whatever had been current before. An unanchored
  rebuild starts from the top.
- **The Grand Hunt banner says whether your first run this week is spent.** Only
  the first hunt each week pays the Epic bag, and only that bag holds the mount
  — so a live banner still advertising it means the run is unspent, and one
  naming a lesser bag means it has been taken. That is the client answering
  about *this character*, with no quest id anyone had to guess. It marks a gate
  done and never reopens one: a recorded turn-in is direct evidence, this is an
  inference, and direct evidence wins.
- A **missing** banner still means nothing at all. The hunt runs in one of four
  zones and rotates, so absence means it is elsewhere, or the zone is not
  loaded, or the map is filtered. That confusion hid this exact goal once
  before, so it is now a check rather than a comment.
- **A weekly event you finished while the addon was not watching also catches
  up.** Completion was only ever seen live on the turn-in, so finishing the
  Grand Hunt in another session left it at the top of the plan all week. The
  quest id is not invented — it is LEARNED from a turn-in that matched by
  title, kept, and asked about on later logins. The first completion still has
  to be seen; every one after it is answerable cold.

- **The contribution file could not be imported back for soloability.** Its own
  export wrote `solo = true   -- or false`, and the hint parsed as part of the
  value, so every answered line was refused. Filling the file in and pasting it
  back produced one complaint per answer. The placeholder is now `?`, which is
  ignored like every other placeholder, and an inline hint is taken off the
  value before it is read — but never off a quoted zone name, which is allowed
  to contain anything.
- The round-trip check could not have caught this. An untouched template is a
  no-op, and a rejected line is also a no-op — two different reasons for the
  same silence. It now asserts the import raised **no complaints**, and fills a
  line in whichever gap this client actually has rather than only drop rates.
- **Thirty soloability judgements recorded** — the whole open list bar one,
  each answered rather than inferred from the category or the expansion. The
  gap this client can see drops from 31 to 1.
- **`Shadow of Doubt` is marked unobtainable — it was never implemented.** Its
  spell, item, zone and achievement id all resolve, and the achievement id came
  from the client's own index, so every automated check agreed it was real.
  What no check can see is whether an achievement's criteria were ever switched
  on. Confirmed in play, against what the files say. Not filed as `REMOVED`,
  which would claim it was obtainable once and stopped being so — a different
  statement about history, and untrue here.
- With that settled, the soloability gap this client can see is **zero**.
- **A record can state why it is unobtainable, and that wins.** The generic
  status line read "No longer obtainable", which asserts the thing *was*
  obtainable once — true of retired TCG loot and past promotions, untrue of
  anything that shipped in the files and was never switched on. The fallback is
  now the neutral "Not obtainable", and `Shadow of Doubt` says "Never
  implemented" in its own words.
- **The report claimed 199 unfixable gaps that were not gaps.** The scorecard's
  "outside the denominator" note counted item conditions with no `itemID` — and
  not one item condition uses that field. 199 carry `id`, which is what the cost
  path reads. So it advertised 207 platform limits where there are 8, and buried
  the eight real ones inside them. Understating our own data is still misstating
  it, and the eight were the whole point of printing the line.
- **Three self-tests could only ever pass.** One narrated where a fresh window
  lands without looking; one stated a rule in its own comment — never prefer an
  unpositionable map when a same-named sibling works — and then counted instead
  of checking it; one asserted the plan anchor had held while standing exactly
  where it was charted, which cannot be told from a live read. The first two
  now assert. The third says it cannot tell, which is the honest answer.
- **Answering every open question used to switch the importer check off.** It
  picked a mount out of the export to fill in, so a client with nothing left to
  contribute skipped the half that matters. That is backwards — a finished
  database is when you most want to know the importer still works, because it
  is when nobody is exercising it by hand. It takes a record from the database
  now instead.

## 1.1.11 — 2026-08-07

- **The built-in arrow is now the default, and TomTom is opt-in.** TomTom has a
  single crazy arrow and a great many addons write to it — whichever wrote last
  owns the screen. A route could be steered off mid-leg by something with
  nothing to do with mounts, and from the player's side that just looked like
  Master Mounts pointing at the wrong place. The built-in arrow answers to
  nothing else, so it is what ships on.
- **Existing installs are moved once**, and it is recorded, so anyone who ticks
  the box straight back is never un-ticked again on a later login. Settings are
  normally left alone; this one is moved because `on` was never a choice anyone
  made — it was the old default, and it misbehaves.
- **Switching it now takes effect on the step you are on, in both directions.**
  Nothing re-ran the dispatch when the setting changed, so flipping it mid-route
  did nothing visible until the next step: turning TomTom off left its waypoint
  standing and never brought the built-in arrow back, and turning it on left the
  built-in arrow up while TomTom got nothing. The current step is remembered now
  — at the moment the setting flips, the code that knows where you are heading
  is not the code doing the flipping.
- **The teleport count was reporting the route length.** "81 legs of this route
  use a teleport" on an 81-stop route was not a coincidence — the check asked
  whether a stop had a travel method at all, and every routed stop has one.
  Multi-leg journeys are tagged as taxi rides (a taxi can be ridden again, a
  teleport cannot — that distinction is how charges get spent), so they all
  counted. It now asks the real question, and asks it both ways: a teleport that
  lands you there directly, and a journey whose first leg spends a charge.
- **The route header and its stops were quoting two different clocks.** "1d 0h
  on the route" counts travel plus a single visit to each stop; the per-stop
  "1d 3h in" counts against the whole job, grinding included. Both were right
  and neither said so, so stop 8 appeared to land three hours after a route the
  header said took a day. They now name their clocks — "travelling and visiting"
  against "to finish everything" — and a check asserts the first can never
  exceed the second, and that no stop lands past the end of the plan.
- A check reports which arrow is actually driving rather than which one the
  setting asked for. The two differ on purpose for cross-continent legs, which
  always use the built-in arrow because TomTom's one arrow cannot express a
  multi-step route.

- **Fifteen crafted mounts stop being hidden by a profession nobody needs.** All
  22 records with a `PROFESSION` condition were held back identically, and they
  are three situations. Five need the profession *to ride* — the flying carpets,
  the flying machines. Two are Archaeology solves nobody can do for you. The
  other fifteen are BoE or ordinary crafting orders: the six panthers, the
  `Mechano-Hog` and `Mekgineer's Chopper` that sell on the auction house, the
  `Sandstone Drake`. Holding those back was the opposite of what the gate is for
  — it exists to stop the router sending you where nothing can happen, and
  something can happen here.
- Marked **per record after reading each source line**, never inferred from the
  profession: *"engineers only"* and *"BoE, purchasable"* are the same shape of
  condition and opposite answers.
- **No commission is invented.** A crafting order costs reagents plus a tip. All
  fifteen carry real reagent data harvested from the client; the tip is not
  knowable, so nothing is written down for it. A check asserts every tradeable
  craft still carries a cost, because making one available without one would
  turn it into free work that outranks the real kind.

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
