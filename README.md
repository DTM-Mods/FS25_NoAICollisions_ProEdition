<p align="center">
  <a href="https://github.com/DTM-Mods"><img src="https://raw.githubusercontent.com/DTM-Mods/.github/main/assets/dtm-header.jpg" alt="DTM Mods by PropaineX & Fennell" width="100%"></a>
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/DTM-Mods/.github/main/assets/icons/FS25_NoAICollisions_ProEdition.png" alt="No AI Collisions Pro Edition icon" width="128">
</p>

<h1 align="center">No AI Collisions Pro Edition</h1>

<p align="center">
  <img src="https://img.shields.io/badge/Farming%20Simulator-25-2E6B4F" alt="Farming Simulator 25">
  <a href="https://github.com/DTM-Mods/FS25_NoAICollisions_ProEdition/releases/latest"><img src="https://img.shields.io/github/v/release/DTM-Mods/FS25_NoAICollisions_ProEdition?label=version&color=D9A441" alt="Latest version"></a>
  <img src="https://img.shields.io/badge/multiplayer-supported-2E6B4F" alt="Multiplayer supported">
  <a href="https://github.com/DTM-Mods"><img src="https://img.shields.io/badge/DTM-Mods-143326" alt="DTM Mods"></a>
</p>

<p align="center">
  <b>Never get stuck in AI traffic again.</b><br>
  <sub>by PropaineX</sub>
</p>

<p align="center">
  <a href="https://github.com/DTM-Mods/FS25_NoAICollisions_ProEdition/releases/latest"><img src="https://img.shields.io/badge/Download-latest%20release-D9A441?style=for-the-badge&logo=github&logoColor=143326&labelColor=E9C77A" alt="Download the latest release"></a>
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/DTM-Mods/.github/main/assets/features.jpg" alt="Features" width="100%">
</p>

Never get stuck in AI traffic again. AI traffic behaves like in the base game (it stops and waits for you,
moving cars are solid), but a traffic car that stands still near one of your vehicles for a couple of seconds
becomes pass-through, and turns solid again once it drives off and is clear of your vehicles.
Helpers (base game, AutoDrive and Courseplay) that are stopped by an obstruction for 2 seconds turn off
collisions with it and carry on along their course, forwards or reversing. Two helpers that block each other
drive through each other, but a helper queueing with a gap is never pushed into. Collisions come back as soon
as the obstruction is cleared. Works in single player and multiplayer, no settings needed.

<p align="center">
  <img src="https://raw.githubusercontent.com/DTM-Mods/.github/main/assets/installation.jpg" alt="Installation" width="100%">
</p>

Download `FS25_NoAICollisions_ProEdition.zip` from the [latest release](https://github.com/DTM-Mods/FS25_NoAICollisions_ProEdition/releases/latest) and put it in `Documents/My Games/FarmingSimulator2025/mods`, without unzipping or renaming it. In multiplayer, the server and every player need the same version.

<p align="center">
  <img src="https://raw.githubusercontent.com/DTM-Mods/.github/main/assets/license.jpg" alt="License" width="100%">
</p>

MIT, see `LICENSE`.

<details>
<summary><b>For developers</b>: files, building and tests</summary>

### Building the zip yourself

Zip the CONTENTS of this folder (modDesc.xml at the top of the zip, forward-slash paths) as
`FS25_NoAICollisions_ProEdition.zip` and put it in the FS25 `mods` folder. Don't rename the zip.

### Files

- `modDesc.xml` - mod description
- `scripts/NoAICollisions.lua` - traffic pass-through and helper unblocking
- `icon_NoAICollisions.dds` - shop icon

</details>

---

<p align="center">
  <a href="https://github.com/DTM-Mods"><img src="https://raw.githubusercontent.com/DTM-Mods/.github/main/assets/dtm-intro.gif" alt="DTM Mods by PropaineX & Fennell" width="420"></a><br>
  <sub>Part of <a href="https://github.com/DTM-Mods">DTM Mods</a> (Dead To Me) by PropaineX & Fennell</sub>
</p>
