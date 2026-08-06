# Changelog

## 1.1.0

**Routing now runs on measured times instead of straight-line guesses.**

- **Measured flight durations.** 785 flight masters, 4,054 hops, real observed
  seconds each. A flight follows a scripted path with turns, altitude and a
  takeoff, so distance-over-speed was wrong in both directions and never by a
  consistent factor. Multi-hop routes use them too, not just direct flights.
- **The portal / ship / zeppelin / tram network.** 1,156 endpoints with real
  coordinates and 238 connections. These legs are not distance at all — a portal
  is fifteen seconds and half a world — and were previously priced as a flat hub
  charge or not modelled as connections at all.
- The two compete: whichever is genuinely faster wins, and the network returns
  nothing when it cannot connect two points, so it only ever replaces an answer
  with a cheaper one.
- `/mm travel` now opens by stating what both datasets cover, so a suspicious
  route can be diagnosed without guessing which half failed to load.

Durations that the source states are used as given; the rest take a per-method
default that is labelled ASSUMED, so the time model keeps reporting measured
versus assumed honestly.

## 1.0.0

First release.

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
