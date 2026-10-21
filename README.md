# No AI Collisions Pro Edition (FS25)

Farming Simulator 25 mod by PropaineX. Version 1.3.4.0.

Never get stuck in AI traffic again. AI traffic behaves like in the base game (it stops and waits for you,
moving cars are solid), but a traffic car that stands still near one of your vehicles for a couple of seconds
becomes pass-through, and turns solid again once it drives off and is clear of your vehicles.
Helpers (base game, AutoDrive and Courseplay) that are stopped by an obstruction for 2 seconds turn off
collisions with it and carry on along their course, forwards or reversing. Two helpers that block each other
drive through each other, but a helper queueing with a gap is never pushed into. Collisions come back as soon
as the obstruction is cleared. Works in single player and multiplayer, no settings needed.

## Files
- `modDesc.xml` - mod description
- `scripts/NoAICollisions.lua` - traffic pass-through and helper unblocking
- `icon_NoAICollisions.dds` - shop icon

## Install
Zip the CONTENTS of this folder (modDesc.xml at the top of the zip, forward-slash paths) as
`FS25_NoAICollisions_ProEdition.zip` and put it in the FS25 `mods` folder. Don't rename the zip.

## License
MIT, see `LICENSE`.
