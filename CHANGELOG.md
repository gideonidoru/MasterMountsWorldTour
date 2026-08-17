# Changelog

## 1.2.4 — 2026-08-16

Twenty-five records named mounts the game does not have, and one real mount was
filed as gone.

### Mounts that were never there

- **Twenty-five phantom records removed**, taking the database from 1,621 to
  1,596. Every one named a mount with no entry in the game's own mount table:
  the same mount catalogued twice under a spelling never used (Sunflash for
  Sunflare, Scorching Courage for Scorching Valor), an item recorded as though
  it were the mount it teaches, a garrison ability, a druid shapeshift form,
  and six that simply are not in the game. A phantom is indistinguishable from
  a missing mount in every count that walks the database, so each one had been
  reported as a gap in your collection that no amount of play could close.

- **A real mount was recovered.** The Ultramarine Qiraji Battle Tank was marked
  as an unobtainable TCG loot card. It is an archaeology mount — a rare Tol'vir
  solve for 150 fragments — and it is obtainable today. Chasing a phantom found
  it, because the phantom was the archaeology *project* filed beside it.

- **Reins of the Quantum Courser is recorded as a source, on all sixteen mounts
  it can give.** It drops from Chrono-Lord Deios in Dawn of the Infinite and
  grants a mount you do not already own, so it can never be a duplicate. Eleven
  of the sixteen are published under an item name that differs from the mount's
  own — Deathcharger's Reins is Rivendare's Deathcharger, Mummified Raptor Skull
  is Tomb Stalker — and each now says so in its own tooltip.

- **The Brewfest Bomber offers the queue instead of a walk.** Three mounts drop
  from Coren Direbrew's one daily chest, and the third disagreed with the other
  two about which instance it was, what difficulty it ran at, and where the door
  is. It alone was routed as a journey to a mountainside.

### Under the hood

- **Two self-test checks now actually run.** Both were written against data that
  only exists while the database is being built, so in a shipped copy they
  reported "not declared" and counted as skipped. They now check the database
  you loaded: that no removed record has come back, and that all sixteen
  Quantum Courser mounts still name their source.

- **Archaeology mounts stopped asking for a recipe.** Nothing is combined to
  make them, so they will never have a reagent list, and they now say that
  rather than sitting in a list headed "open a profession window".

- **The published files no longer carry anyone's home directory.**

## 1.2.3 — 2026-08-16

Places you could not get to, and a line break the journal writes as two
characters.

### Getting there

- **The Coiled Isle is reachable.** It sat 4,226 yards off the coast with no
  route to it, so four mounts there were never planned. The three gates down
  into the Vaults of Atal'Utek, the Siren Isle ship and mole machine, and two
  instance doors read from the game's own point-of-interest data are all
  recorded now — Siren Isle alone had six goals and no way in.

- **Twelve Coiled Isle rares are watched for.** Ruby Writhe and Topaz Skyfang
  drop from any of them and named no creature at all, which meant the rare alert
  never fired and the map showed nothing. Every one now has a coordinate,
  including the two that are not simply standing there.

- **Every named vendor has a coordinate.** The list that reports this was
  reading a different table from the one the route reads, so five vendors looked
  answered and were not.

### Saying what is actually true

- **Thirteen mounts missing from the catalogue were a line break.** The journal
  writes one as the two characters `|n`, not as a newline, and the export that
  finds uncatalogued mounts only looked for the latter.

- **Horrific Visions are retired, and the planner did not know.** Two mounts
  were still being routed toward content nobody can enter — twelve hours of
  budgeted work for the motorbike alone. Both are parked with their steps and
  coordinates intact, against the content returning.

- **Four achievement requirements named the wrong achievement**, including one
  that named the other faction's version.

- **The Skull of Er'inye is not on the isle**, and a mount is no longer charged
  for an item nobody can loot.

## 1.2.2 — 2026-08-16

Player reports, and a zone that had been quietly costing more than it should.

### Reported by players

- **The Nether-Swept Drake is fished in Voidstorm, not bought in Outland.** The
  record was already right about where; it now carries the item id as an item
  id. A spell id had been recorded in that field, which is how the wrong vendor
  ended up attached to it.

- **Killing a boss no longer throws an error.** 12.0 withholds some strings the
  client used to hand over, and reading one as text threw. Three calls were
  unguarded; the one that fired per boss kill is what people actually saw.

- **The rare alert's arrow points at the spawn.** It was reading world axes as
  though they were a compass, which on Magisters' Terrace put it 179 degrees
  out -- reliably away from the rare.

- **The alert no longer stalls a frame.** Setting the audio volume and loading
  the model both happened in the same frame the window appeared. Both now
  happen after it is on screen.

- **Timewalking mounts are not offered when no Timewalking week is running.**
  Detection was fixed in 1.2.1; the recommendation never asked. "Add 10
  easiest" now skips work that cannot be started today.

### Saying what is actually true

- **Engineering teleports are looked for in the toybox, where they live.**
  Every one of them is a toy, not an item in your bags, and the rule that knew
  that existed in one place and was written a second time without it. Five
  devices were reported first as blocked by an unreadable skill and then as not
  owned, on a character holding all of them. Possession is now one rule, asked
  in one place, and the self-test cross-checks it against the client's own
  toybox so the two cannot drift apart again.

- **"You don't have it" is said before a skill level is blamed.** Requirements
  were tested before possession, so something you did not have reported a skill
  problem -- which reads as a capability withheld from somebody who earned it.

- **An unreadable skill level is no longer called zero.** This client reports
  every expansion skill line as 0 while naming five professions through another
  reader. The report printed "nothing levelled, which is correct on a character
  with no professions" three lines below the list of professions. It now prints
  both readers and says the level is unreadable, which is what it is.

### Travel

- **A zone joins the travel network from its own map.** Portals are published
  as points of interest, both ends, with positions -- so Voidstorm, which had
  no travel node and priced all fourteen of its goals as leave-and-return, now
  routes through the portal it actually has. Four links read this way, kept
  across sessions, and re-read on login for anything new.

  A link is only made when BOTH ends are read. One end plus an assumption about
  the other is how a route sends somebody through a door that is not there --
  which nearly happened, when "Portal to Silvermoon" resolved to the Burning
  Crusade city rather than the one next door. Place names now resolve near the
  map that names them.

- **A zone reached under a second map id is no longer called unreachable.**
  Every K'aresh travel node is recorded on Tazavesh, which UiMap.db2 gives as a
  CHILD of K'aresh -- so the gap report asked for a portal from Dornogal that
  has shipped since the first release, while the router was already travelling
  through it. A node inside a sub-zone is inside the zone that holds it. The
  same reading recovered Vashj'ir and Ashran; the off-network list fell from
  eight zones to five, and the five that remain genuinely have none.

  The reverse is refused. A node somewhere on a continent says nothing about
  whether one place inside it can be reached, and accepting that would mark
  most of the world reachable.

### Faster

- **The route builds in about 25 ms**, from roughly 740. Three separate
  causes, all the same shape -- work repeated inside a loop that could not
  change it. The route panel now reports where its time went and whether the
  stored chart was reused.

### Honesty

- **The report says what it cannot do, rather than blaming the planner.** A
  zone off the travel network is now named as that, and the survey list leaves
  out dungeon and raid maps -- you do not reach a raid by portal.

- **Costs that were one flat number are now counted**: a quest chain's length,
  and a visit that is measured rather than assumed.

- **Ids are graded on whether they measure what their condition names**, which
  found five that differ from the client deliberately and confirmed the rest.


## 1.2.1 — 2026-08-16

Mostly player reports, and the things they turned out to be hiding. Several of
these were one wrong answer feeding half a dozen visible symptoms.

### The planner was telling you to buy things you could not buy

- **A finished Timewalking week read as one still running.** The calendar lists
  a holiday on EVERY day it covers, not only on its start and end Tuesdays, so
  scanning back a week and finding any entry meant last week's event kept the
  vendor open for days after it closed. That single wrong answer produced
  everything reported: badge mounts passed the availability gate, their rows
  were tagged "ending soon" with nothing to end, and the badge line advertised
  a purchase that could not be made. The newest calendar marker now decides.

- **A full purse no longer promises a purchase with no event running.** The
  "you have enough badges" branch returned before the event check below it ever
  ran, so it always said to go and buy. It now says what it is waiting for.

- **Rank gates measured the wrong season.** Renown ids are minted per season,
  and both the Delver's Journey and Preyseeker's Journey gates pointed at a
  previous expansion's track — so a character carrying last season's rank 10
  was told it had met a requirement it had never started, and the mount was
  offered as ready to collect. Both now name this season's track.

- **A mount's row named the requirement blocking it.** With several conditions
  on one mount it reported whichever was written first: a player holding
  thousands of Voidlight Marl saw the marl, and nothing about the rank that
  actually barred the purchase.

- **Four currency ids were wrong.** Two covenant mounts charged Reservoir Anima
  under the name Grateful Offering, and a Dragonflight mount measured Dream
  Infusion against the Dragon Isles Supplies id from the line beneath it.

- **The two Magisters' Terrace dungeons are told apart**, and a dungeon remake
  no longer erases the original when ids are harvested. Reported from play as
  a route that confused the two.

### The route

- **Work you cannot finish by turning up no longer leads.** "You are already
  here" is meant to save travel on something you can act on now, and it
  measures the visit rather than the grind — a one-in-a-thousand rare is a
  whole attempt every time you show up. But a tier shortcut skipped that
  measurement entirely, so a treasure still wanting a thousand items was pinned
  to position five against a thirteen-day estimate.

- **A tooltip no longer says "guaranteed this visit" above a thirteen-day
  estimate.** Certainty there is about the reward, not about today.

- **Vile Essence is counted.** The client can now read how many you hold
  instead of charging everyone the full thousand.

### The window

- **A grey metal border no longer runs behind the planner's lists.** It was
  Blizzard chrome from the window's own template that no theme had ever
  collected, because it lives one level deeper than the sweep was looking.

- **The close button works on every theme.** ElvUI is the only theme that shows
  the native button rather than drawing its own, so two separate faults in the
  shared theme code were visible there and nowhere else: one hid it, the other
  dropped its atlas and drew the entire icon sheet in its place.

- **Blizzard and ElvUI reach the same standard as Modern.** The Blizzard look
  handled four of the thirteen surfaces the interface registers — the columns,
  wells and cards are frames the addon creates, with no native art to fall back
  on, so an unhandled one rendered as nothing at all. ElvUI's inset styling was
  written but unreachable.

- **The collection bar's figures are readable.** Near-white text on the fill was
  about 1.4:1, and ElvUI took its colour from the player's own profile, so it
  could be dimmer still.

- **The planner window was rebuilt** around the material set it borrows: real
  panes, wells that sit inside them, scroll bars in line with every other one
  in the addon, a proper empty state, and a count of what is left to choose
  from.

### Housekeeping

- **The addon stops hoarding its own diagnostics.** Running the id export wrote
  about 53 KB into saved variables every time and nothing ever read it back;
  a diagnostic report saved another 87 KB and was never pruned. Both were then
  reloaded and reparsed at every login, on every character, for the life of the
  account. The export is now kept only on clients with no copy window — the
  case it was actually for — the report is capped, and anything already stored
  is shed once on upgrade.

- **The kill-debounce table is swept.** It held a name for every boss killed in
  a session to suppress duplicate counting for five seconds, and then kept it
  for the rest of the session.

- **The theme artwork is credited**, and the licence no longer overclaims it.

- **A price that lands on nothing now stops the build.** Prices are attached by
  matching a condition's name, and a rename matched nothing, priced nothing and
  said nothing — the shipped addon cannot see this, because those are resolved
  when the database is built. Turning the check on found one that had been
  wrong for some time: Soaring Meaderbee's 900 Sizzling Cinderpollen was
  outranked by an older, emptier record of the same name.

## 1.2.0 — 2026-08-15

Minor rather than patch: numbers you already read start reading differently.
Every saved route chart is rebuilt once on first login after upgrading, because
the router now records far more about what a chart was built for.

- **A kill counts for every mount it could have dropped.** The attempt watch
  list held one mount per creature, so where a source owes several — Coren
  Direbrew owes both Brewfest mounts, and twelve creatures owe 27 mounts
  between them — only the last one planned was counted. The rest sat at zero
  and read as bad luck. Worse, the one being counted was whichever happened to
  be planned last, which could be a mount already collected. Attempts are no
  longer double-counted either, when a boss kill and the loot from it arrive as
  two separate signals.

- **Weights that did nothing now do something.** The route's cache could not
  see the era nudge, deadline pressure, the reorder cap or the tier order, so a
  chart built at one setting was restored at another and the slider read as
  decorative. It could not see a teleport being switched off either, so the
  route kept routing through a portal you had just disabled.

- **Two places in one zone are no longer given the same directions.** Journeys
  were computed from your coordinates and then cached under the zone name
  alone, so the second stop in a zone inherited the first one's route —
  including its entry flight point, which may be on the opposite side.

- **One hearthstone can no longer pay for a whole route.** A teleport used as
  the first leg of a longer trip was never marked as spent, so a plan was
  costed as though you carried one charge per stop. Session lengths were costed
  the same way, and now measure travel exactly as the route does.

- **A route that fails to build no longer takes the working one with it.** The
  route is published in one piece, at the end, together with its totals, its
  index and its session count — so a build that goes wrong leaves the last good
  route exactly where it was instead of half-replacing it.

- **Patch 12.1 is treated as live.** Its mounts no longer wait behind a date
  check, its bosses are named so kills there count, and its records no longer
  describe themselves as unreleased content in a tooltip you read while
  standing in the zone.

- **The planner's travel line is the route's travel line.** The plan tooltip
  computed its own estimate rather than reading the router's, so the two
  surfaces could quote different numbers for the same journey.

- **It got faster.** Charting an 82-stop route fell from 346 ms to about 50 ms.
  Editing the plan while a route is active no longer freezes the frame — the
  work is chunked, and the last edit measured 0 ms on frame. Travel lookups
  reuse their search 98% of the time, and the minimap driver stands down when
  there is nothing left to move.

- **The interface has a themed surface.** Panes are real regions with their own
  edges and resting colour rather than one black canvas, and the ElvUI and
  Blizzard skins inherit the same structure with their own accent.

## 1.1.15

- **Continent maps no longer bury themselves in mount pins.** Projecting every
  child zone's pins up onto the continent map worked for Pandaria and the Broken
  Isles and silently produced nothing for Outland, Zandalar and the Dragon
  Isles, because those parent maps are not a simple projection of their
  children. Half a feature reads as two separate bugs — two continents unusable
  under overlapping icons, and mounts apparently missing on the rest. It is off
  by default now, with a checkbox for anyone who wants it, and the zone maps
  have always shown everything.

- **The Darkshore warfront rares come in faction pairs, and ours were crossed.**
  Each nightsaber was tagged with one faction and standing on the *other*
  faction's rare, so the goal passed the faction gate and then sent a Horde
  player to an Alliance-only spawn. Ashenvale Chimaera claimed Horde when its
  rare serves both, and Blackpaw claimed neither when its rare is Horde only.
  Every correction moves a record onto the rare it already named.
- **Pathfinder's Den is not in the Cleft of Shadow.** It is reached from the
  Gates of Orgrimmar, which our own access notes already said. The portal there
  is labelled **Zuldazar**, not Dazar'alor, and the instruction now names the
  stairs — a waypoint has no vertical axis, so a player on the top floor was
  being told they had arrived.
- **A Wowhead link with an implausible spell id is refused.** Two mounts opened
  pages for spell 27 and spell 24 while their records carry the right ids. The
  record's id now wins over the row's, an id too small to be a mount falls back
  to a name search, and the anomaly is printed so it arrives with the number
  attached next time.
- **The minimap quick menu opens at the cursor**, not against the screen edge
  where it had no room to lay out.

- **Chel the Chip is where Abundance is, not where it was.** The route sent
  players to a fixed point in the middle of the troll camp in Zul'Aman when the
  event was running somewhere else entirely. Abundance now uses the same live
  read the Grand Hunt does — the zone in the record is only a fallback for when
  the client cannot be asked. Voidstorm is in the rotation because it was seen
  there; our own source text listed three zones and was simply incomplete.
- **The report now says which kinds of client string this client hands over.**
  Five separate reports have been one 12.0 change wearing different clothes, and
  every time the answer to "what else is secret?" was a guess. It is measured
  now, against live values, and a payload the addon *depends* on going secret
  fails the self-test rather than surfacing as a crash days later.

- **The Travel panel drew blank a second time, for a different reason.** The
  scroll child was sized from a frame that has no width yet when the panel is
  built, so it came out one pixel across and clipped every row and the group
  button — while the title and blurb, which are siblings of the scroll frame
  rather than children of it, drew perfectly. It now falls back to a sensible
  width and redraws once the frame really has one. An empty list also says it is
  empty, since blank has now meant three different things on this page.
- **The Travel panel drew blank until something was clicked.** Its only draw was
  an OnShow the Settings framework never sent, so the frames existed with no
  text or rows in them — one unlabelled button on an empty page. It draws when
  it is built now, and the dungeon group switch sits with its own section
  instead of above the whole page.
- **Switching a teleport off did not reach the route.** The switch cleared a
  cached list from two hundred lines above where that cache is declared, so Lua
  wrote a global of the same name and left the real one untouched — the option
  vanished from the settings and the router kept serving the list it already
  had. The build now fails on a file-level local assigned above its declaration,
  which is worse than the read it already caught: a read is nil and usually
  throws, a write silently succeeds against the wrong variable.
- **Teleports can be switched off.** Options > Master Mounts > Travel lists
  every teleport this character can actually press, and an unticked one is never
  suggested and never priced into a route. Dungeon and raid teleports have a
  single switch for the lot, because "don't spend my M+ charges" is one decision
  rather than eighty. The router is not wrong to price those — they really are
  the fastest way in — but nothing it can measure will ever tell it you are
  saving them for a key.

- **Killing an open-world rare blocked the alert from hiding.** The alert frame
  parents a secure macro button — an addon cannot call TargetUnit, so the
  "Target" button has to be one — and Blizzard refuses to show or hide the
  parent of a secure button in combat, exactly as it refuses to set the child's
  attributes. Reported twice now with the same shape: the SetAttribute call sat
  under a combat check with a comment explaining why, and the Show and Hide four
  lines away did not.

  The waiting now lives in one place instead of one copy per file, and the same
  sweep found the arrow's own HUD container unguarded — it parents the secure
  action button, so hiding it was refused for the same reason and had simply
  never been reported.

## 1.1.14 — 2026-08-07

- **Zoning into a delve threw on every nameplate.** A unit's GUID is a
  client-supplied string exactly as its name is, so splitting one to read the
  npc id throws when 12.0 withholds it — and the GUID is read on the line
  *before* the name, so the name guard added earlier went straight past it.
  Three files each kept their own copy of that six-line parse, which is why the
  same fault existed in three places at once. It is parsed in one guarded place
  now, and the build fails if another copy appears.

- **The guard against unreadable client strings was itself throwing.** It
  concatenated inside a pcall and then tested the result outside it, on the
  belief that concatenation is the operation a secret value refuses. It is not —
  a secret concatenates and yields another secret, and the comparison afterwards
  is what throws. So the one place everything had been routed through became the
  error site, which is worse than the scattered reads it replaced. Every
  operation now happens inside the pcall, and what comes out is a plain string
  or nothing.
- **The self-test was modelling a bug the client does not have.** Its fixture
  errored on concatenation, so it confirmed a shape that never occurs and
  reported a pass while the real thing threw in a delve.

- **Rare alerts threw on every nameplate, mouseover and target in a delve.** A
  unit's name is a secret value inside an instance on 12.0, and reading one
  as a string throws. Losing the name costs almost nothing — a watched rare is
  matched on the npc id from its GUID first, and the alert can name it from the
  record it matched rather than from a string the client will not hand over.
  The vendor-name read had the same hole and is closed too.
- **The build now refuses to ship an unguarded unit-name read.** This mistake
  shipped three times: a boss name, then a vignette name, then three unit events
  at once — each in a different file, each a few lines from something already
  guarded, and each costing a live report because nothing pointed at the next
  one. The player's own name is excluded, because that is never withheld.

- **The arrow's action button was blocked in combat.** It is a secure button,
  and Blizzard protects the frame — not just its attributes — so `Show` and
  `Hide` are refused in combat exactly as `SetAttribute` is. The attribute
  writes were guarded from the start and the visibility was not. It surfaced in
  a delve because a delve is wall-to-wall combat and the arrow re-evaluates on
  every step of the route; anywhere else there is a lull for the deferred state
  to drain in. Visibility now defers and is applied when combat ends, and a
  deferred show can still be cancelled.
- **A refused call is reported once, not once per attempt.** The block was a
  real bug, but printing it every single time it happened was a second one — a
  protected call is refused inside combat, which is when an addon is busiest, so
  one missing guard filled a chat frame. Refusals are also kept and counted now,
  so the self-test can state that nobody's client refused us anything instead of
  the evidence living only in chat.

- **A Burning Crusade mount routed to Draenor.** Warlords rebuilt Draenor using
  names Outland already had: Nagrand is map 107 and 550, Shadowmoon Valley 104
  and 539, Shattrath City 111 and 594. Dark War Talbuk is bought with Halaa
  tokens in Outland's Nagrand and resolved to Draenor's — a different continent,
  not a misplaced pin. Every record naming one of those three zones now states
  its own map, read from that record's own source text, and the resolver has to
  agree with it.

  No rule decides this, because every rule tried was wrong. The expansion looks
  like the answer until Amani Hunting Bear, a Dragonflight-era record whose
  vendor stands in Outland's Shattrath selling for Timewarped Badges.

  Vendor locations carry the same pin, for a subtler reason: a record only uses
  its own zone when that zone has coordinates, so a mount that names a city with
  no point in it falls through to whoever sells it — and the vendor's entry
  stated a zone and a point but no map. The pin on the record was right and
  simply never consulted.

- **A check for the one routing mistake the data can actually make.** Warlords
  rebuilt Draenor using names Outland already had, so Nagrand, Shadowmoon Valley
  and Shattrath City are each two maps on two continents, and the shipped id
  table picks the Outland copy for all three. Every Draenor stable mount names
  one of those zones. It is simulated rather than observed, because confirming
  it by hand needs the mount set as a goal and a mount you already own can never
  be one — so the routes most worth checking are the ones a player cannot check.

  It is deliberately narrow, after two broader versions were wrong. One treated
  any name with several maps as risky and failed on Azsuna, which is several
  maps all on the Broken Isles. The other required a goal to sit on a continent
  its expansion uses elsewhere, and failed on a PvP mount sold in Stormwind —
  an expansion does not confine its mounts to its own continent. Vendors sit in
  capitals and holidays sit in old zones, and neither is a fault.

- **The wrong-continent check audited four zones and reported the number as
  coverage.** Its whole purpose is catching a goal that attaches to an entry
  point an ocean away, and it probed Tazavesh, Ny'alotha, The Forbidden Reach
  and Sanctum of Domination — by name, and nothing else. It now walks every
  cross-zone attachment made this session, the route's own included. The zones
  worth probing are the ones nobody thinks to list: the fallback it guards only
  runs where a zone has no nodes of its own.
- **That audit measured against the wrong map for some nodes.** It converted a
  node's coordinates using its zone's canonical map, while the router uses the
  node's own — and a link whose far end sits in a sub-map is still filed under
  the parent zone. It could invent an offender, or miss one, by itself.

## 1.1.13 — 2026-08-07

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
