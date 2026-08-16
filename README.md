# Master Mounts – World Tour

[![CurseForge](https://img.shields.io/badge/CurseForge-Master%20Mounts%20World%20Tour-f16436)](https://www.curseforge.com/wow/addons/master-mounts-world-tour)

**Download:** [CurseForge](https://www.curseforge.com/wow/addons/master-mounts-world-tour)

A mount-collection addon for World of Warcraft retail that answers the question
a checklist can't: **what should I actually do tonight?**

It catalogues 1,608 mounts, works out which ones you can make progress on right
now, and plans a route through them — ordered by real travel time, using your
teleports, hearthstones and portals.

## What it does

- **Routes, doesn't list.** Stops are ordered by travel cost, not alphabetically.
  It knows a Hearthstone to Valdrakken beats a 3,500-yard flight, and that five
  Island Expedition mounts are one visit rather than five.
- **Fits your session.** Tell it you have 45 minutes and it gives you a plan
  that fits in 45 minutes.
- **Learns your pace.** It times how long you actually take to clear an
  instance and folds that into a running average — per character, because the
  same raid falls over faster to a hunter than to a warrior.
- **Charges what's left, not the whole grind.** A reputation mount two-thirds
  of the way to exalted costs the remaining third. A paragon cache already
  earned costs five minutes. A PvP season reward is priced as the number of
  matches you still need to win, at your own win rate.
- **Urgency is a clock.** A daily whose window closes tonight outranks a weekly
  you still have four days for — scaled by how much of the window is spent,
  not by a flag saying a lockout exists.
- **Points at the right character.** Mounts gated on reputation, currency or a
  profession say which of your characters is closest — and a craft names the
  trade and the rank, so "Blacksmithing 300" doesn't read as satisfied by an
  apprentice.
- **Tracks attempts** account-wide, and never implies a pity timer, because
  there isn't one.
- **Explains itself.** Every goal can say why it landed where it did —
  preference, shared stop, or travel time.
- Nav arrow, map pins, rare alerts, TomTom support, ElvUI theming.

## The unusual part

**The addon knows what it doesn't know, and says so.**

Around a third of its time estimates are assumptions rather than measurements —
prices only readable while standing at a vendor, drop rates nobody has ever
observed, achievements it can only read as prose. Rather than hiding that behind
a confident number:

- every estimate is tagged `measured` or `assumed`, and `/mm timemodel` shows
  the split
- unknowns are costed **pessimistically**, so something it can't price can never
  outrank real work — the ORDER stays sound even where the TOTAL is an upper bound
- `/mm score` computes a scorecard from live state, with nothing asserted, and
  itemises what it's missing

Some things genuinely cannot be known by anyone: soloability of legacy raids
depends on class, gear and patch and no API exposes it; a drop rate nobody has
observed does not exist to look up; WoW exposes no reverse lookup from an item
or quest NAME to its id, from the client or anywhere else. Those are recorded as
unknown rather than guessed, and the scorecard leaves the platform limits out of
its denominator rather than pegging itself below 100 forever for something
nobody can fix. Inventing the numbers would make them look better and be worth
less.

## Commands

| Command | What it does |
|---|---|
| `/mm` | open the main window |
| `/mm route` | start / stop the route |
| `/mm session 45` | plan for a 45-minute sitting |
| `/mm report` | full diagnostic, into a copyable window |
| `/mm score` | the scorecard, computed live |
| `/mm timemodel` | measured vs assumed split |
| `/mm contribute` | export the gaps a player could answer |
| `/mm resolve` | resolve ids from the client |
| `/mm costs` | where each estimate's number comes from |
| `/mm gaps` | what's missing, and whether anyone could supply it |
| `/mm whynot` | why a planned mount isn't in the route |
| `/mm compare` | mounts someone in your group has that you don't |
| `/mm selftest` | run the checks (214 of them) against live state |

`/mm` on its own opens the window; `/mm report` bundles every diagnostic into
one copyable dump.

## Helping it get better

`/mm contribute` exports the gaps that a player standing in the right place
could actually answer — a vendor price, a coordinate, whether a legacy raid
soloed. Import merges someone else's export back in.

Some of the unmatched names may be typos in our data rather than platform
limits; that export is how they get found.

## Installation

Drop the `MasterMountsWorldTour` folder into `Interface/AddOns/`. The folder must
keep that exact name — the `.toc` and the art paths are derived from it.

Retail only, tested against 12.0.7 (Midnight).

## License

[MIT](LICENSE).

Bundled libraries under `Libs/` are third-party and carry their own licenses:
LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0.
