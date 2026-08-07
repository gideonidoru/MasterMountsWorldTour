# Changelog

## 1.1.5 — unreleased

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


## 1.1.0 — unreleased

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
