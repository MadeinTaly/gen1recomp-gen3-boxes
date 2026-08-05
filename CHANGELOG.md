# Changelog

## 1.5.2 — the black screen, and a cursor you can find

- **Fixed: everything outside the cells was black**, the header and footer
  included.

  The screen emitted a palette zone per Pokémon and nothing else, so those
  were the only remapped pixels on the frame — the rest composited black,
  and text drawn in black on it simply disappeared. There is now a **base
  zone covering the whole surface**, drawn first with the per-Pokémon zones
  on top, which is exactly what `SummaryMenu` does.

  `PaletteFX.whole()` is not usable for it: that helper is hardcoded to the
  160×144 tile grid and would have covered a quarter of a BIG canvas — the
  same bug wearing a helpful-looking name. The size comes from the layout.

- **Fixed: the cursor was a hairline.** It was a one-pixel outline one
  pixel outside a cell that already has its own one-pixel outline — two
  identical shapes a pixel apart, on a 56-pixel cell. It is now four
  **corner brackets**, scaled to the cell (2px arms on CLASSIC, 4px on
  BIG), which read as a cursor at any size and leave the middle of the cell
  clear so the Pokémon is not fenced in.

## 1.5.1 — BIG was broken on a real screen

**If you are on 1.5.0 with `GRID` set to `BIG`, update.** The colours were
right; everything around them was not.

- **Fixed: the footer printed across the grid.** It was drawn at `y=132`, a
  number taken from the Game Boy screen and never adapted. On the 288-tall
  BIG canvas that is the middle of the grid, so `B:EXIT` landed on top of
  the Pokémon.

- **Fixed: palettes bled across the box.** `sgbPalettes` emitted zones for
  **both** panes at once. The box grid and the party pane overlap by
  design — only one is drawn at a time — so the party's palettes were
  painted in stripes over the box. Only the visible pane is zoned now.

- **Fixed: lines were measured against 160** even on a 320-wide surface, so
  a message was cut at nineteen glyphs with half the screen empty beside
  it.

- **Fixed: a custom sprite drew over its neighbours.** Pics come through
  `Assets.image`, which is the seam a sprite mod shadows — the README calls
  that a feature — so a 112×112 or 168×168 replacement is a thing that
  happens. The scale was a fixed 0.5/1.0, and a 2× pic overflowed a BIG
  cell by a whole cell, a 3× one by two. It is now derived from the picture
  the game actually hands over, still in whole steps so two-bit art stays
  crisp.

Every one of these is now a test: text is collected as it is drawn and
checked against the surface and against the grid rectangle, zones are
checked for overlap, and the scale is checked across seven picture sizes in
both layouts.

## 1.5.0 — the grid in colour

- **`GRID`** — `CLASSIC` (as before) or **`BIG`**.

  `BIG` asks the renderer for a **320×288** surface instead of 160×144, and
  two things follow from the one number that makes it worth doing, **56**:

  **Battle pics draw at scale 1.** A pic is 56×56 and the cell is now 56.
  Not halved, not stretched — every pixel of the sprite is one pixel of the
  canvas. It is the first time this screen has shown one undamaged.

  **Every Pokémon wears its own colours.** 56 is *seven tiles exactly*, and
  a palette zone is addressed in tiles — so each cell can carry the
  species' own palette, the same table the summary screen and the battle
  use. A Charmander is orange, a Bulbasaur green and a Gengar purple, all
  at once, in one grid. That is what Gen 3 storage looks like and what Gen
  1 never had the hardware to draw: the Game Boy could show four palettes,
  and this shows twenty-one.

  `CLASSIC` cannot do either, and the reason is the same number: a
  28-pixel cell is three and a half tiles, and half a tile cannot carry a
  zone at all.

  There is nothing to restore. `Game:draw` asks the **top state** for its
  surface every frame and passes 160×144 when the state has no opinion, so
  the moment this screen is not on top the game is back on the Game Boy
  canvas — no enter hook, no exit hook, no way to leave the rest of the
  game wearing a canvas it did not ask for.

  **What it does not buy:** sharper Pokémon. The sprites are the ROM's own
  art and cannot be redrawn, so `BIG` buys *room and colour*, not detail.

## 1.4.0

- **`BOX HEALS`** (off) — close the box screen and everything in storage is
  rested: full HP, status cleared, every move's PP back.

  It is the Pokémon Centre's own routine rather than an imitation.
  `Pokemon.heal` is what `engine/events/heal_party.asm` `HealParty` does,
  PP-Up bonus included, and the nurse calls that same function — storage
  that quietly healed a differently-shaped amount would be worse than
  storage that did not heal at all.

  **Once, on closing, not on each placement.** Healing per move would have
  meant deciding what a move even is: a deposit heals, but a swap is a
  deposit and a withdrawal at the same time, and dragging a Pokémon between
  two box slots is neither. `StateStack` calls `exit()` on pop and only on
  pop — opening the summary on top of the screen does not fire it — so "the
  player is done with the boxes" is something the engine already tells us.

  **Every box, not only the open one.** One put away in box 3 an hour ago is
  as deposited as one dropped a second ago, and *"rested unless you happened
  to be looking at that box when you left"* is not a rule anybody could hold
  in their head.

  The party is left alone. Not to police anything — you can deposit six and
  take them straight back — but because the party is the half of this screen
  that is not storage, and a screen that rested your active six for opening
  and closing it would be a Centre with extra steps.

  Off by default: free healing is an economy change, not a convenience. What
  stops being needed is Potions and trips to town.

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
