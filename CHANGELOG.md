# Changelog

## 1.2.2

Three fixes to the session picker, all reported from live play.

- **Choosing a length no longer starts a route.** It flipped the route on and
  threw the goal window on screen before you'd pressed Start Route. The picker
  is a setting; `/mm session 45` still means go now, because there the verb is
  explicit.
- **The goal counter honours the session.** It read the whole plan
  unconditionally, so picking "20 minutes" still announced 107 goals — the
  session promised one thing and the counter said another.
- **Removed the session row from the goal window.** It belongs on the Planner,
  and having it in both places invited exactly the confusion above.

## 1.2.1

- **Fixed: the session dropdown never showed your choice.** It kept reading
  "No limit" after you picked a length. `WowStyle1DropdownTemplate` is a
  DropdownButton, not a Button — `SetText` does nothing on it. The label setter
  is `SetDefaultText`.
- The control now shows the chosen length ("20 minutes", "3 hours") rather than
  a countdown; the route monitor already shows time remaining. The off state
  reads "No limit" in both the control and the menu.

## 1.2.0

**The Optimize button is gone, because it never optimized anything.**

- **Removed "Optimize".** It called `Router:Build()` and then rewrote your plan
  to match the route it had just built — but Build reads the plan as an
  unordered set and applies its own ordering every time, pressed or not. The
  route was never what the button improved. All it did was overwrite the manual
  plan order from the per-row arrows, while implying your route was second-rate
  until you found it. **The route has always been optimized automatically.**
- **Session length is now a dropdown** in the toolbar, stating what it is set to
  rather than four buttons and a label.
- **Toolbar regrouped** into act / set / look:
  `[Auto-Plan All] [Add 10 Easiest] [Clear Plan] | [Session] | [Available] [Category] [Sort]`.
  Clear Plan now sits with the two buttons it undoes, at the end of its group
  where destructive actions belong.

## 1.1.0

**Session planning is now where you'd look for it, and it actually does what it says.**

- **Session picker on the Planner.** It was previously reachable only from
  Options > Weights & Priorities, or by knowing `/mm session` existed.
- **A session now reorders the route.** This is the real fix: the addon worked
  out which stops fit your time, kept only the *count*, and then routed you
  through the whole plan in the ordinary order. It announced "45 minutes: 2
  stops" and walked you through 106. The fitted stops now move to the front.

  Reordered rather than truncated, so nothing is lost — running over, or ending
  the session, continues into the rest of the plan.
- The route monitor also shows the session row, for checking time remaining
  mid-route.

## 1.0.0

First release.

- 1,608 mounts catalogued with source, drop rate, lockout and prerequisites
- Routes across every expansion, pricing portals, ships, flight paths and
  teleport items to find the genuinely quickest path
- Groups mounts that share a stop
- Rare alerts driven by vignette data, filtered to mounts you're missing
- Attempts tracked account-wide, with no implied pity timer
- Every estimate tagged measured or assumed; unknowns costed pessimistically so
  a guess can never outrank real work
- Warband-aware reputation, currency and professions
- Nav arrow, map pins, TomTom and MountsRarity support
