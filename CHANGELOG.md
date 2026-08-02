# Changelog

## 1.3.0

### Changed

- **START opens the summary; B goes back.** The two have swapped.

  B now means back and only back — the convention every other screen in this
  game follows — and shelving a carried Pokémon first, so it is never
  dropped out of the save. Because the way out no longer disappears on any
  cell, START is free to be the summary.

  1.2.0 had it the other way round and had to work around itself: B was the
  summary over a Pokémon and the exit over an empty cell, which meant a full
  box — where every cell holds one — had no exit at all, so START had to
  carry it.

## 1.2.1

### Added

- **In-game updates.** The manifest now declares its `github` repo, which is
  what the launcher's updater reads and what the "Find mods" tab installs
  from. Releases are named `gen3_box-<version>.zip`, the exact name
  `ModUpdate.pickZipAsset` prefers — a test asserts the manifest and that
  file name still agree, because the two drifting apart would silently
  demote the updater to "grab whatever zip is attached".

## 1.2.0

### Added

- **B over a Pokémon opens its summary.** The same screen the rest of the
  game uses, which recalculates a box mon's stat block on the way in
  because the box struct carries none — so a Pokémon that has never been in
  your party still shows real numbers.

### Fixed

- **The footer ran off the right-hand edge.** Every glyph in this font
  advances 8 pixels and the screen is 160 wide, so a line has room for
  nineteen of them. The `SELECT:PARTY START:BOX` hint was twenty-two — 176
  pixels — and the tail was simply off the screen. The hints are short now,
  and nothing is drawn without being measured against the screen first. A
  test collects every line the screen draws, in six different states, and
  fails if any of them passes 160 pixels.

- **A Pokémon whose species is no longer installed crashed the screen.** A
  save written while a species-adding mod was enabled still names those
  species after it is turned off; the name lookup assumed the record was
  always there. It falls back to the raw id now.

### Changed

- **START closes the screen; the boxes are changed by walking off the left
  or right edge**, the way Ruby's L/R do. START had to stop being "next
  box": with B over a Pokémon meaning STATS, a full box — where every cell
  holds one — would otherwise have had no way out at all.

## 1.1.0

### Added

- **The Pokémon Center PC opens it too.** A BOXES row is inserted right under
  the box PC's own row, through the engine's `ui.pc.items` hook.

  That row is labelled "SOMEONE'S PC" until you meet Bill and "BILL'S PC"
  after, so anchoring on one label alone would have silently stopped working
  halfway through the game. Both are tried, and an unrecognised menu puts the
  row at the front rather than dropping it.

- **OPEN FROM**, choosing where it is reachable: `START+PC`, `START` or `PC`.
  Read per menu, so changing it takes effect on the next menu that opens
  rather than the next boot.

## 1.0.0

- First release. A 5x4 grid storage screen with a pick-up/put-down cursor,
  box switching on START, and a party pane on SELECT.
