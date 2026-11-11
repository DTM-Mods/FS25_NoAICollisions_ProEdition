# Planned fix: contact check (BUILT in 1.5.0.0)

Written 2026-11-10 (Claude). Status: **built 2026-11-10 in 1.5.0.0** (`updateContacts`, `probeContacts`,
`ghostVehicle` in scripts/NoAICollisions.lua). Mock test passed (13 checks); untested in the game, not zipped.
Version now: 1.4.1.0. This fix would be a new feature, so it would ship as 1.5.0.0. This is a Pro Edition of someone
else's mod, so ask before changing anything.

## The problem seen in the game

An AutoDrive unloader (truck and trailer, "Unload combine") steered sideways into a moving beet harvester (a Ropa run by
Courseplay). It pushed the harvester right off its row. NoAICollisions never let them pass through each other.

## Why the mod doesn't step in

`scripts/NoAICollisions.lua` only passes a helper through something when **all** of these are true:

- the helper has been **stopped** for `BLOCK_TIME` (2 s), or for `STUCK_TIME` (2 s) when it is trying to drive but
  not moving;
- a box check finds the obstruction **in its path**: up to `PROBE_LENGTH` (15 m) in front of it, or behind it when
  reversing;
- for another helper (the Courseplay harvester counts as one): the two are deadlocked, or touching.

In this case the truck was **moving**, and the harvester was **beside** its path, not in it. None of these were true, so
collisions stayed on and the truck pushed the harvester.

## The fix

Add a **contact check** for AutoDrive helpers:

- Every scan (`SCAN_INTERVAL`, 500 ms), look for other vehicles touching the helper's body. Touching means within
  `CONTACT_MARGIN` (0.3 m, already in the mod) of any shape of the helper or its trailers, on any side, not only ahead.
- When a helper touches another vehicle (a game vehicle or another helper), switch off collision for that pair only,
  the same way the mod already does (pair collision, wheels included, so it doesn't climb onto the other vehicle).
  Do this whether the helper is moving or stopped.
- Switch the pair's collision back on once they are `PAIR_CLEAR_GAP` (2 m) apart, the same as now.
- Log it once per contact, e.g. `[NoAICollisions] <truck> touching <harvester>, passing through until 2 m apart`.

Keep as they are:

- The queue rules: helpers waiting in line at a silo or a pin with a gap are left alone. They never touch, so the
  contact check doesn't fire.
- Traffic cars and world objects keep the current rules.
- The helper's own load (pallets, bales and the like) never counts as contact.

## Why it's only a backup

AutoDrive Overdrive od.56 (2026-11-10) fixed the cause on the AutoDrive side: the unloader keeps a gap from the
harvester's outline, steers away, drops back or stops, and never reverses into its front. This contact check would only
catch whatever still touches, so a push can't drag a machine off its row.

## How to test it (when built)

- A mock test with two vehicles side by side, one helper moving sideways into the other. Collision for the pair
  switches off while they touch and back on at 2 m apart. Also check that a queue of helpers with a gap is left alone.
- In the game: an AutoDrive unloader chasing a Courseplay harvester. Look for the log line, and check the harvester is
  never pushed.
- Bump the version to 1.5.0.0 and add a patch notes entry.
