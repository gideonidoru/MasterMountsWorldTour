# Changelog

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
