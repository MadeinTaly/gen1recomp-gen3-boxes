# Changelog

## 1.10.0 — a wallpaper is a place and a hand

The seven scenes were drawn here, badly, and nobody had ever looked at them.
This release does two things about that: it makes them possible to look at,
and it stops them being the only choice.

**A renderer that did not exist.** A pattern that lives only as code cannot
be judged by reading it, and these never had been — the forest was a field of
green dots, the snow was invisible, the cave was a beige wall with teeth at
the edges. `tests/_render.lua` stubs `love.graphics`, calls the real drawing
code and writes the frames out, so every scene in this release was looked at
before it shipped. It found a bug on its first run: NIGHT was passing a
NEGATIVE alpha to `setColor`, which LOVE tolerates in silence.

**All seven redrawn**, as tile motifs rather than vector shapes: trees with
trunks, waves with crests, a town under snowfall, a cave with pillars and
crystals, a crescent moon over the city, a sun over blocky clouds, stars that
are actually scattered rather than marching in diagonal columns. And **90S**,
which is not a place: two layers of shapes crossing in opposite directions,
the pattern that was on every folder in 1994.

**Other people's art, chosen by hand.** Nine wallpapers by seven pixel
artists ship alongside — ansimuz, MatiasVME, DustDFG, FabinhoSC, Admurin,
Scribe and leyren — under CC0 or CC BY, credited in `THIRD_PARTY_NOTICES.md`
and, more usefully, in the menu itself. The art ships **as the artist made
it**: CLASSIC shows it whole, and GRID BIG flattens it through the engine's
own palette pass, so one file serves both.

**The chooser is a place and a hand.** WALLPAPER no longer opens a list over
the box; it borrows the footer and lets the box itself be the preview:

    FOREST                     < ADMURIN > FAV

Up and down change the scene, left and right change the artist, and the
wallpaper behind is exactly what you will get. Every box keeps its own pair,
so two boxes can both be FOREST in two different hands. SELECT adds what you
are looking at to your FAVOURITES — press it again to take it out — and the
FAVOURITE category wears one of them. START shuffles both at once. Until you
touch the D-pad the footer says which keys do what, then gets out of the way.

**Only what loops, moves.** Each style ships as a stack of layers, and
whether a layer scrolls is measured rather than guessed: the mean difference
between its first and last columns says whether it continues into itself.
Clouds, water, mist and stars loop, so they drift; buildings, mountains and
rock do not, so they hold still. An earlier build slid everything and dragged
a visible seam across the box every few seconds.

Saves written by 1.9.x still work: a bare wallpaper name means that scene,
drawn here.

## 1.9.3 — a way out, the right colours, and the cell behind you

Three reports, three seams, none of them the same bug. 1.9.3-beta.1 went out
as a pre-release first, and two of the three reporters came back on it: the
soft lock and the follower's cell are confirmed fixed on a real screen, not
only in the code. The third (#4, Crystal sprites) is confirmed from the
engine's own trueColor contract and ships with them.



**START on a Pokemon soft-locked Gold (#5).** The two summary screens are
not closed the same way and this screen treated them as if they were. Gen 1's
pops itself — A or B off page two is `game.stack:pop()`
(`src/ui/SummaryMenu.lua:65`), so handing it the mon and walking away is the
whole call. Gold's does not: every exit path in `src/ui/gen2/SummaryMenu.lua`
ends at `self:close()`, and `close()` is `if self.onClose then self.onClose()
end` (`:664-666`). With no callback, B does nothing at all and the screen
stays on the stack forever. Gold's own PC passes one
(`src/ui/gen2/BoxMenu.lua:309-313`) and so does its party menu; this screen
was the only caller that did not. It passes one now, behind the same
`pcall(Screens.get, ...)` guard the vanilla PC uses, so an engine build
without the screen leaves STATS inert rather than throwing inside a menu.
Red, Blue and Yellow are untouched — that path was already right.

**Crystal sprites came out in somebody else's palette (#4).** Every cell
wears its species' four-colour SGB palette, and the renderer's shader reads
the pixels under that zone as four DMG greys and maps them onto those four
colours. That is right for a Gen 1 battle pic and wrong for art that is
already coloured: real RGB pixels pick their new colour by brightness, out of
a ramp that has nothing to do with them.

The engine has carried the answer all along, and this screen was throwing it
away. `Sprites.path` returns `path, trueColor` — the sprite mod's own word
for "this art is already coloured", set either on the species record or on
the ctx by its `pokemon.sprite` hook — and `picOf` captured only the path.
The flag now travels with the image to `drawPic`, which reports the rect the
coloured art covers through `PaletteFX.markTrueColor`. The renderer splices
those rects into the pass as `colors = false` zones and re-blits them
unshaded over the colourised frame, which is exactly what the engine's own
summary screen does with its pic (`src/ui/SummaryMenu.lua:118-124`). The cell
around the sprite keeps its species palette and the wallpaper keeps its own,
so nothing else on the screen moves. Wilds of Kanto's overworld sprites go
through the same path, read from that mod's own `trueColor` convention
(unset means full colour, `lib/sprite_providers.lua:119-125`). Vanilla art
never sets the flag: on a mod-free boot nothing is reported and the frame is
the one 1.9.2 drew.

**One test moved, for a reason worth writing down.** The engine now refuses a
mod any `src.*.gen2.*` module while the running game is Gen 1 — "the structs
it reads and writes are not this game's, so anything it stores lands on the
save in the wrong shape" (`src/mods/Loader.lua`, `crossGenerationDenial`).
The MAIL check here had been faking a Gen 2 save onto the Gen 1 harness, and
that is exactly the thing the rule exists to stop. Nothing in the screen
changed: on Gold the module resolves and the letters follow their Pokémon as
they always did. The test simply boots the generation it is testing now.

**The follower came back standing on you (#3).** 1.9.2 rebuilt the right
follower and put it in the wrong place, and the reporter said so. That is not
a choice this screen makes: `syncAll` always asks for `mapEnter = true`
(`lib/follower/control_engine.lua:4056-4060`), and a map entry with no walked
trail behind it parks the pack on the player's own cell so it walks out from
under him — the Red/Blue door-exit look (`:2418-2432`). Nobody walks anywhere
while the box is open, so that branch is the one that runs every time.

There is no mid-map mode on that export to ask for instead, so the cells are
remembered before the rebuild and given back after it, the way that mod's own
`placeTrailerAt` writes them (`:2199-2207`) and with the trail cell moved
along, since `pokepcTrailCells` is what the pack walks back down on the next
step. The restore is deliberately narrow: only a trailer that came back
standing exactly on the player is moved. A rebuild that changed the number of
followers goes down that mod's own grow/trim path with its positions already
intact, and this leaves it alone.

## 1.9.2 — the other follower, the one that was actually on screen

1.9.1 respawned the **engine's** follower when the party changed, and the
report stayed open. The reason is worth writing down: Wilds of Kanto does not
ride `PikachuFollower` at all. It keeps its own trailing entities and
designates the follower through save data (`pokepcLeader` /
`followerPartyIndex`) rather than party order — so 1.9.1 was rebuilding
something that was never the thing on screen.

That mod exports `syncAll(game, ow)`, and it does precisely what a map change
does, which is exactly what the reporter noticed fixes it: removes the
trailers, clears the player's cached control species, re-syncs the control
visual, and rebuilds the trailers with `mapEnter = true`. So the screen calls
it on the way out, next to the engine respawn, when the party changed.

Neither call is required for the other to work, and every path is guarded:

- **Wilds of Kanto absent** — `mod.find` answers nil, and only the engine
  follower is respawned.
- **Installed but switched off** — `mod.find` calls `isActive`
  (`src/mods/Loader.lua:1239`) and answers nil for a disabled or failed mod,
  so a player who turned it off does not have this screen reaching into it.
- **An older version without `syncAll`** — the export is type-checked and the
  screen degrades to the engine follower.
- **Gen 1 and Gold alike** — `src.world.PikachuFollower` is one of the fifteen
  names the Gen 2 adapter serves, and the live overworld is handed over under
  whichever name that game spells it (`game.overworld` or `game.world`).

The worst case anywhere is the behaviour before this release, never a throw
while the screen is closing.

## 1.9.1 — the follower is told when the party changes

Reported: deposit the shiny that is following you, withdraw an ordinary
Pokémon, close the screen — and the follower behind you is still the shiny
one, until you change maps or step into a Pokémon Centre.

Nothing here was wrong about the party: it really did change. What was missing
is that anything was **said** about it. This screen moves Pokémon with its own
table operations rather than through the vanilla PC's flow, and the follower
is spawned once and then left alone — it is rebuilt on
`PikachuFollower.onMapEntered`, which is exactly why walking through a door
fixes it. A follower mod reads the Pokémon at spawn time, so a stale entity
keeps the old species, the old palette and the old shininess.

So the screen now asks for that rebuild on the way out, and only when the
party it opened with is not the party it is closing with — identity, not
contents, so any swap, deposit or withdrawal counts and an untouched visit
does not twitch the thing behind you for no reason.

The respawn is `viaMapLoad = false`: the mid-map respawn the engine already
uses for a bike dismount or a revive, which puts the follower on the cell
behind the player rather than under him as a fresh map entry would.

One call covers both games. `src.world.PikachuFollower` is one of the fifteen
names the Gen 2 adapter serves, resolving to `src/world/gen2/Follower.lua` on
a Gold boot with the same signature; only the overworld is spelled
differently (`game.overworld` against `game.world`), and that is the one
branch.

## 1.9.0 — the box is somewhere, and a shiny is not its species

Two things: the wallpaper became a place, and issue #2 is fixed.

### The shiny fix (issue #2)

Two Pokémon of the same species — one shiny, one ordinary — drew the SAME
picture, whichever of the two was resolved first.

The screen was asking the wrong question: it read `spriteFront` off the
species record, and a species has one record and one path, so nothing in the
question could tell two Pokémon apart and a mod supplying shiny art was never
consulted at all. The picture now goes through `src/pokemon/Sprites.lua`,
which raises `pokemon.sprite` with the live mon in its ctx — the field the
engine itself calls "per-instance skins". The overworld-sprite cache was keyed
by species for the same reason and is keyed by the mon now, with weak keys.

Crucially, the per-instance answer is a **candidate, not a verdict**: a mod
that renders a Pokémon some other way (voxels, 3D) answers with something
`Assets.image` cannot load, and treating that as "no picture" drew an empty
grid. If it yields no image, the species record is used and the cell still
draws.

### The wallpaper

- **It covers the whole screen.** The scene runs edge to edge, margins and the
  gaps between slots included; only the title row and footer are painted back
  to white, because they are black text.

- **Scenes instead of shapes**, the way Gen 3 named its wallpapers after
  places: **SEA** (swell rolling opposite ways, bubbles rising), **FOREST** (a
  swaying canopy), **SKY** (two cloud layers at different speeds), **CAVE**
  (still rock, with a drip), **CITY** (a skyline whose windows light and go
  dark), **SNOW** (flakes drifting sideways as they fall) and **NIGHT** (stars
  twinkling out of phase, on the reversed ramp that makes it a real dark
  mode). PLAIN still draws nothing.

- **The grid's slots are laid over the scene**, and **`SLOTS`** chooses how
  opaque they are: CLEAR, 25%, 40% (the default), 60%, 80%. CLEAR is no slot
  at all — the scene straight through.

- **`ANIMATE`** (on by default) turns all motion off, and off is phase zero:
  pixel-for-pixel a still wallpaper, for anyone who finds movement
  distracting or cannot look at it.

Everything is drawn in code from colours authored in this repo. No art is
copied from anywhere and `modkit lint` reports no ROM-derived content.

The motion clock ticks once per **logic** step rather than per drawn frame, so
it runs at the same speed on any machine, and every scene's phase is taken
modulo its own period — a box left open for an hour draws what it drew in the
first minute.

## 1.8.0 — it runs on Gold

Same release as `1.8.0-beta.1`, shipped stable: Gold plays, so a Gen 2 player
should be updated into this rather than have to go looking for it.

Nothing about the Gen 1 screen changes. Every Gen 1 assertion in the suite is
the one it was, and the suite is green on both generations.

- **`"games": ["gen1", "gen2"]`** in the manifest. A mod is not loaded on a
  Gold boot unless it says it is for Gold; without the claim the manager lists
  it as `ENABLED (NOT THIS GAME)` and nothing else happens.

- **Fourteen boxes, not twelve.** Gold's storage is 14 boxes of 20, and this
  screen already read `Boxes.COUNT` and `Boxes.CAPACITY` rather than spelling
  either number, so the grid, JUMP TO BOX, FIND's wrap-around and the flat
  box-and-slot ring all widened on their own. On Gold those constants come off
  the engine's own adapter over `src/core/gen2/Boxes.lua`.

- **The summary screen is a different screen on Gold.** Gen 2's builtins carry
  a `Gen2` prefix and its summary takes an options table rather than the mon —
  `Screens.push(game, "Gen2SummaryMenu", { mon = mon })` against Gen 1's
  `Screens.push(game, "SummaryMenu", mon)`. START over a Pokémon opened nothing
  at all before this.

- **The stat block is Gen 2's.** `Stats.ensure` computes Gen 1's five stats,
  Special included, which is the wrong block for a Gen 2 mon: Gold splits it
  into `specialAttack` and `specialDefense`. A mon withdrawn on Gold now has a
  missing block filled by `src/battle/gen2/Mon.lua`'s own formula instead.

- **BOX HEALS works on Gold.** `Pokemon.heal` restores PP out of the Gen 1
  `Data` singleton and reads a stat block a box mon may not carry, so on Gold
  the guard around it made the whole feature a silent no-op. The Gen 2 path is
  `HealParty`'s own recipe read off `game.data.moves`.

- **MAIL is respected.** Gold keeps letters in `sPartyMail`, a sparse array
  keyed by *party slot*. This screen moves mons with its own table operations,
  so on a Gen 2 boot it now refuses to pick up or displace a party Pokémon
  holding mail — `Remove MAIL.`, the vanilla PC's own one-liner — and keeps
  every other letter aligned with its owner across the party changes it makes.

- **The BOXES row lands in the right PC.** On Gold the `ui.pc.items` hook fires
  at two menus: the storage system and the player's own ITEM PC. The row is
  added to the first and not the second, told apart by the `CHANGE BOX` row
  only the storage menu has.

- **`GRID BIG` is CLASSIC on Gold.** `BIG` is built on two Gen 1 seams Gold's
  boot does not have: `Game:draw` asking the top state for a `uiSize()` and
  then for its `sgbPalettes()` zones. `src/core/Game2.lua` does neither — it
  scales one Game Boy canvas — so a 320×288 layout would have been drawn into
  a 160×144 frame and fallen off the edge of it. On a Gold boot the option is
  read as `CLASSIC` whatever it is set to, and the OPTIONS row says so. Nothing
  changes for a Gen 1 save, including one whose option is set to `BIG`.

  The same seam is why a wallpaper's four colours do not reach the surround on
  Gold: the palette zones are a Super Game Boy trick, and Gold draws in colour
  of its own. The pattern is drawn as it always was.

## 1.7.0 — overworld sprites, when you have them

- **OW SPRITES** — when [Wilds of Kanto](https://github.com/YoDrehDenSwagAuf/overworld-spawn-mod)
  (`overworld_wild_spawns`) is installed and enabled, and `GRID` is `CLASSIC`,
  the box grid and the party pane draw that mod's own per-species overworld
  sprite in each occupied cell instead of the half-scale battle picture. It
  is a whole sprite rather than a halved one, at an integer scale, the same
  rule `picScale` already follows for a replaced battle pic.

  It is asked the way that mod is already proven to answer: through the
  follower sprite service behind the icons it draws in the vanilla party
  menu, which honours the **Sprite Style** chosen over there. Its general
  `spriteProviders` seam is tried second, so the feature survives if that
  party-menu path is ever retired.

  It does **nothing at all** unless that mod is installed: reached through
  the engine's own `mod.find`, not a manifest dependency, so this stays an
  optional enhancement rather than a requirement. `GRID BIG` is untouched --
  its cell is 56, a battle pic already draws there at scale 1, and a
  16-pixel overworld sprite would have to be blown up four times to fill it.

  Every call into the other mod's code is guarded: a missing handle, a
  black-fallback silhouette, or a resolver that throws all fall back
  silently to the battle picture that has always worked, rather than a
  half-drawn cell or a crashed frame. Nothing of that mod's art is copied
  into this repo -- this only ever asks it, at runtime, for a path.

  **On by default**, because with that mod absent the feature is one `nil`
  check and the picture this screen always drew.

## 1.6.1 — the menu you could not see

1.6.0 put six features behind the header row and told nobody it was there.
The footer hint that named it only ever drew on an **empty** cell, because an
occupied one shows the Pokémon's name instead — and the cell under the cursor
is occupied nearly all the time. So unless you happened to press UP on the top
row and notice something had changed, the entire release was invisible and the
screen looked exactly like 1.5.2.

Two fixes, both about being seen rather than about behaviour:

- **A MENU button is drawn on the title row**, right-aligned and outlined so
  it reads as pressable. It is the same menu the header's A always opened —
  no new binding, no new state, just the affordance the header needed from
  the start. The title gives way to it rather than running underneath: an
  eight-glyph box name plus ` 20/20` is wider than a CLASSIC screen has left
  once the button has its corner.
- **Opening the screen says `UP: BOX MENU` once**, through the ordinary notice
  channel, so it fades after a second and a half and the footer goes back to
  naming what the cursor is on. A hint that stayed would compete with the
  thing it was pointing at.

Nothing else changed. Every control, option and save field is exactly what
1.6.0 shipped.

## 1.6.0 — search, sort, marks, names, and a cry when it lands

- **FIND and FIND NEXT** — search every box by species, type, or mark. Open
  the BOX MENU and choose FIND, then pick a search kind: type a species name
  or nickname substring, pick a type, or pick a mark. The cursor moves to the
  first match. START on the header (which costs no binding) finds the next
  match, wrapping back around to where you started.

- **JUMP TO BOX** — the BOX MENU shows all twelve boxes with their names and
  population. Pick one and jump there without a save prompt.

- **SORT** — order the current box by species ID, level (descending), name, or
  type. UNDO keeps one snapshot per box for as long as the screen is open and
  refuses if the box has changed since. The sort is stable and never reshuffles
  equal keys.

- **MARKS** — Gen 3's four marks (CIRCLE, SQUARE, TRIANGLE, HEART) now live on
  each Pokémon. Enter MARK MODE from the BOX MENU; A opens the marking window
  instead of picking the Pokémon up. Toggle each mark in the window and B
  closes it. Marks draw as small filled shapes in the corner of the cell.

- **BOX NAMES and WALLPAPERS** — give each box a custom name up to eight glyphs
  (shown in the header and JUMP TO BOX), or return to the numbered default by
  typing `BOX n`. Choose a wallpaper: PLAIN (the default), STRIPES, CHECKS,
  DOTS, WAVES, or NIGHT (a dark mode). The pattern draws behind the cells in
  both layouts, and the colour palette replaces the whole-screen base zone, so
  the header and footer stay readable. Every colour is authored in the mod —
  nothing is copied from a ROM — and PLAIN still emits exactly what 1.5.2 drew.
  Names and wallpapers travel with the save.

- **PLACE CRY** — every landing plays the Pokémon's cry. On by default, because
  it changes nothing but sound. A refused landing (full box, full party, nowhere
  to go) plays no cry, because nothing landed.

- **Fixed: Stats.ensure now called on every party landing.** The vanilla PC
  recalculates a box Pokémon's stat block when it leaves the box for the party,
  because `box_struct` carries none — a Pokémon withdrawn from an imported
  `.sav` reaches the party menu with `mon.stats` nil and the HP bar crashes. This
  screen now does the same on every path that puts a Pokémon into `save.party`.

- **Changed: UP from the top row now stops on the header.** With `CURSOR WRAP`
  on, UP from the top row moves onto the header, and UP again wraps to the
  bottom row (not back as in 1.5.2). The header is the one place you need to
  reach to use the BOX MENU and FIND NEXT, so the wrap gains a stop where
  nothing was before.

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
