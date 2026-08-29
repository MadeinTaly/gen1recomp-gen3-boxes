# gen1recomp-gen3-boxes

A Gen 3-style Pokémon storage screen for
[Gen1Recomp](https://github.com/bryanthaboi/gen1recomp): a grid you can see,
and a cursor that picks a Pokémon up and puts it down.

Gen 1's PC shows you twenty names in a list and makes you withdraw, change
box, and re-deposit to move anything. This is the Ruby/Sapphire answer to
that — a 5×4 grid of the current box, one button to grab and drop, and one
button between the box and your party.

## Install

Download `gen3_box-<version>.zip` from
[Releases](../../releases), then in the game:

**Launcher → MODS → Import mod .zip**, or in a running game
**START → MODS → Import mod .zip**.

The launcher can also keep it up to date on its own: the manifest declares
this repo, so **MODS → the mod's row** offers a newer release when one is
published, and it can be installed from the launcher's **Find mods** tab
without touching a file at all.

Requires Gen1Recomp with mod API 2 (engine 0.1.37 or newer). Gold needs
0.1.79 or newer — see **On Gold** below.

## On Gold

The mod runs on Pokémon Gold as well as on Red, Blue and Yellow: the manifest
claims `"games": ["gen1", "gen2"]`, which is what a Gen 2 boot loads a mod on.
Gen 2 support in the engine is a beta, and this port is held to the loader,
`modkit gen2check` and the headless harness rather than to a full playthrough.
It ships stable all the same: Gold plays, so a Gen 2 player is updated into
this the way a Gen 1 player is.

What is different there, and nowhere else:

| | on Gold |
| --- | --- |
| boxes | **14** of 20, not 12 — the grid, JUMP TO BOX and FIND all follow |
| the summary | Gen 2's own summary screen, which is a different screen with a different call |
| stats | a withdrawn Pokémon's missing stat block is Gen 2's, Special split in two |
| BOX HEALS | Gold's own PP table, rather than the Gen 1 one that was never loaded |
| MAIL | a party Pokémon holding mail cannot be picked up or displaced — `Remove MAIL.`, the same refusal the vanilla PC gives |
| the PC entrance | the BOXES row goes in the storage menu, not in the ITEM PC |
| `GRID` | `CLASSIC` always: `BIG` needs two Gen 1 drawing seams Gold's boot does not have |
| wallpapers | the same scenes by the same artists, in the same colours. The screen clips itself there: Gold composes states into a window-sized canvas, so what a scene deliberately draws past its own edge would otherwise land on the border around the Game Boy screen |

Everything else — FIND, SORT, MARKS, NAME BOX, PLACE CRY, the header row and
the BOX MENU — is the same screen doing the same thing.

## Controls

| Key | Action |
| --- | --- |
| D-pad UP (at top row) | move onto the header row |
| D-pad DOWN (at header) | move back into the grid |
| D-pad LEFT/RIGHT (at header) | change box |
| D-pad LEFT/RIGHT (off edge) | change box |
| **A** | pick up / put down — on an occupied slot the two **swap**; on the header, open the BOX MENU |
| **START** | the summary of whatever the cursor is on in the grid; on the header (with a search active) find next |
| **B** | back: carrying one it goes back on a shelf first, otherwise close |
| **SELECT** | cross to the party and back — this is how you deposit and withdraw |

The header row is the box title at the top, reached by moving up from the grid
in CLASSIC or BIG layout. It carries a **MENU** button on its right-hand end —
that is the BOX MENU, and everything this screen gained in 1.6.0 is behind it:
FIND, JUMP TO BOX, SORT, MARK MODE, NAME BOX and WALLPAPER. Press UP from the
top row, then A. B works from anywhere and only back — the convention
every other screen in this game follows — and that is what frees START to be
the summary when the cursor is on a Pokémon. With `CURSOR WRAP` on, UP from
the top row moves to the header, and UP again wraps to the bottom, not back as
in 1.5.2.

## Options

**START → MODS → Gen 3 Box → OPTIONS..**

| Row | Values | Meaning |
| --- | --- | --- |
| `OPEN FROM` | `START+PC` / `START` / `PC` | where the BOXES entry appears |
| `CURSOR WRAP` | on / off | whether the cursor wraps at the edges |
| `BOX HEALS` | on / off | rest everything in storage when the screen closes |
| `PLACE CRY` | on / off | play the Pokémon's cry every time one lands in a slot |
| `GRID` | `CLASSIC` / `BIG` | a 320×288 surface, full-size pics, and a palette per Pokémon |
| `PEEK NEXT BOX` | on / off | show the neighbouring boxes sliced by the screen edge, the way Pokémon Box does. On by default |
| `FULL SCREEN` | on / off | takes the shape of the device and shows **several boxes at once** — as many 5×4 panels as fit, across then down, each with its own name and its own wallpaper. UP from a panel's top row lands on its name, and A there opens the BOX MENU for *that* box. Off the last panel the page scrolls. `GRID` still picks the cell size here — `CLASSIC` fits about twice as many boxes on the screen as `BIG` does. Works on Gold too |
| `SLOTS` | `CLEAR` / `10%` / `15%` / `25%` / `40%` / `60%` / `80%` | how opaque each cell is over the wallpaper. **15%** by default: the cell outline is what says "slot", and twenty squares of white over the art read as a sheet of milk |
| `BANDS` | `SOLID` / `60%` / `30%` / `15%` | how much of the title row and the footer the wallpaper gets. Below `SOLID` the scene runs edge to edge over the whole screen and each caption is written in the scene's own two ends — the letters in one, a one-pixel edge in the other — so the contrast is between two colours out of the same four the picture was painted with. The bands themselves are painted in the scene's lightest tone rather than in white |
| `ANIMATE` | on / off | whether the wallpaper drifts (off is a still wallpaper, pixel for pixel) |
| `OW SPRITES` | on / off | draw Wilds of Kanto's overworld sprites in the `CLASSIC` grid instead of the half-scale battle pics (on by default; does nothing without that mod — see below) |

`OPEN FROM` is read each time a menu opens, so changing it takes effect
immediately rather than on the next boot. `PLACE CRY` is on by default, because
it changes nothing but sound.

The vanilla box PC is left in place whichever way this is set. Nothing is
taken away, and turning the mod off leaves a save reaching its storage
exactly as before.

## GRID: BIG

`BIG` asks the renderer for a **320×288** surface instead of the Game Boy's
160×144. Two things follow from the one number that makes it worth doing —
**56**:

**Battle pics draw at scale 1.** A pic is 56×56 and the cell is now 56, so
every pixel of the sprite is one pixel of the canvas. Not halved, not
stretched. It is the first time this screen has shown one undamaged.

**Every Pokémon wears its own colours.** 56 is *seven tiles exactly*, and a
palette zone is addressed in tiles — so each cell carries that species' own
palette, the same table the summary screen and the battle use. Charmander
orange, Bulbasaur green, Gengar purple, all at once. The Game Boy could
show four palettes on a screen; this shows twenty-one.

`CLASSIC` can do neither, for the same reason: a 28-pixel cell is three and
a half tiles, and half a tile cannot carry a zone.

Nothing has to be restored. `Game:draw` asks the **top state** for its
surface every frame and passes 160×144 when the state has no opinion, so
the moment this screen is not on top the game is back on its own canvas.

**What it does not buy:** sharper Pokémon. The sprites are the ROM's art
and cannot be redrawn, so `BIG` buys room and colour, not detail.

## BOX HEALS

Off by default. Turn it on and closing the box screen rests everything in
storage — full HP, status cleared, every move's PP back. It is the Pokémon
Centre's own routine (`Pokemon.heal`, which is what `HealParty` does, PP-Up
bonus and all), not a lookalike.

It runs **once, when you close**, rather than on each placement. Healing per
move would have meant deciding what a move even is: a deposit heals, but a
swap is a deposit and a withdrawal at once, and dragging a Pokémon between
two box slots is neither. Closing has no such question — whatever ended up
in storage comes out of it rested, however it got there.

**Every box**, not only the one you were looking at, for the same reason:
"rested unless you happened to be on that box when you left" is not a rule
anyone could hold in their head.

The party is untouched. Not to stop you depositing six and taking them
straight back — you can — but because the party is the half of this screen
that is not storage, and resting your active six for opening and closing a
menu would be a Pokémon Centre with extra steps.

It is off by default because it is an economy change rather than a
convenience: what stops being needed is Potions and trips to town.

## FIND

Every box is searched from the cursor forward, wrapping around to where it
started. Open the BOX MENU and choose FIND, then pick a search kind:

- **SPECIES** — type a substring to match against the Pokémon's nickname, its
  species name, or its raw species ID. `CHAR` finds CHARMANDER, and a Pokémon
  nicknamed CHARLIE alike.
- **TYPE** — pick from the list of types. The list is built from every species
  in the data each time, so a mod that adds species does not need to be named
  here.
- **MARK** — pick from the four marks: CIRCLE, SQUARE, TRIANGLE, HEART.

A hit lands the cursor on that Pokémon and reports its name in the footer. A
miss says so and moves nothing. The search is remembered: with a search active,
START on the header row finds the next match. The party is not searched — it is
six visible slots on the same screen.

## JUMP TO BOX

Open the BOX MENU and choose JUMP TO BOX to see all twelve boxes with their
names and population (`n/20`). Pick one and the cursor moves there without a
save prompt.

## SORT

Open the BOX MENU and choose SORT. The options are:

- **BY DEX** — by species ID.
- **BY LEVEL** — descending, strongest first.
- **BY NAME** — by species name, then nickname.
- **BY TYPE** — by the first type, then dex.
- **UNDO** — restore the order before the last sort, if the box has not changed.

Every sort is stable: equal keys stay in their original order. When you undo,
UNDO refuses if the box has changed (a Pokémon arrived or left), and says so.

## MOVE MANY

Open the BOX MENU and choose **MOVE MANY**. **A** ticks and unticks a
Pokémon, **START** moves everything ticked into whichever box you are
looking at, and the BOX MENU entry again turns it off.

It refuses rather than half-moves: a destination without room for all of
them leaves both boxes exactly as they were. The ticks belong to the box
they were made in — walking to another box to tick more would build a
selection whose slot numbers mean different things in different places, so
the ticks stay where they were made and the other box is where they land.

## MARKS

Open the BOX MENU and choose MARK MODE to toggle it on. With it on, A opens the
marking window on a Pokémon instead of picking it up. The window shows four
marks: CIRCLE, SQUARE, TRIANGLE, HEART. Use LEFT/RIGHT or A to pick each one
and toggle it (they draw as small filled shapes in the corner of the cell), and B
to close the window. B from the grid leaves MARK MODE.

## BOX NAMES AND WALLPAPERS

Open the BOX MENU and choose NAME BOX to give the current box a custom name up
to eight glyphs. The name shows in the header and in JUMP TO BOX. An empty
confirm keeps the current name unchanged; to return to the numbered default
(`BOX 1`, `BOX 2`, etc), type `BOX n` back.

Choose WALLPAPER to change the box's background. It does not open a list over
the box: the chooser borrows the footer and lets the box itself be the
preview, so what you are scrolling through is drawn full size behind your
Pokémon while you decide.

```
FOREST                            < ADMURIN > FAV
```

The place is on the left, the hand that drew it on the right.

| Key | In the chooser |
| --- | --- |
| UP / DOWN | change the scene |
| LEFT / RIGHT | change the artist |
| SELECT | add this one to your FAVOURITES — press again to take it out |
| START | shuffle: a random scene and a random artist at once |
| A | keep it for this box |
| B | leave everything as it was |

Until you touch the D-pad the footer tells you which keys do what, then gets
out of the way.

**Every box keeps its own pair**, so two boxes can both be FOREST in two
different hands. **FAVOURITE** is a category with no look of its own: it wears
one of the wallpapers you have marked, so changing your favourites redecorates
every box set to it without touching any of them.

### The scenes, and who drew them

**Sixteen places, ninety-one wallpapers, twenty-seven outside hands.** Every scene is drawn here in code
first — that is the GEN3 BOX entry, and it is what a box wears until you
change it — and then the same place again by pixel artists whose work is CC0
or CC BY. The artist's name is the label you scroll through, which is where
credit actually gets read.

| Scene | Hands | |
| --- | --- | --- |
| SEA | GEN3 BOX · **Scribe** · **Reactorcore** | + DEEP, DAWN |
| FOREST | GEN3 BOX · **ansimuz** · **MatiasVME** | + AUTUMN, NIGHT |
| SKY | GEN3 BOX · **DustDFG** · **FabinhoSC** · **GrumpyDiamond** | + AURORA, DUSK |
| CAVE | GEN3 BOX · **Admurin** · **PWL** · **JonathanPalmerGD** | + ICE, EMBER |
| CITY | GEN3 BOX · **FabinhoSC** · **ansimuz** · **ansimuz (Warped City 2)** | + NEON, DAWN |
| SNOW | GEN3 BOX · **Admurin** · **Emcee Flesher** · **Jetrel** · **Tio Aimar** · **rubberduck** | + DUSK |
| NIGHT | GEN3 BOX · **leyren** · **LLGD** · **fridaruiz** · **tigitalart** | + BLOOD, MOSS |
| DESERT | GEN3 BOX · **Emcee Flesher** · **Cethiel** · **bevouliin.com** | + DUSK, MOON |
| VOLCANO | GEN3 BOX · **Tio Aimar** | + ASH, NIGHT, EMBER |
| SPACE | GEN3 BOX · **TheClicketyBoom** · **Rawdanitsu** · **Bonsaiheldin** · **Screaming Brain Studios** | + RED |
| CASTLE | GEN3 BOX · **Jetrel** · **rubberduck** · **ansimuz** | + DUSK, NIGHT |
| SAKURA | GEN3 BOX | + NIGHT, DUSK, SNOW, EMBER |
| STORM | GEN3 BOX | + NIGHT, DUSK, SEA, MONO |
| CIRCUIT | GEN3 BOX | + AMBER, BLUE, RED, MONO |
| TRAIN | GEN3 BOX | + NIGHT, DUSK, SNOW, SEPIA |
| 90S | GEN3 BOX | + MINT, SUNSET, GRAPE, MONO |

The right-hand column is the same scene drawn here through another palette —
`SAKURA < GEN3 NIGHT >` is a night hanami, not a toggle — so every place has
at least five wallpapers behind it and none has more than seven.

FAVOURITE comes after all of them and stays there: it is a pointer to
whatever you marked with SELECT rather than a place of its own, so it belongs
at the end of the walk rather than in the middle of the real scenes.

CC0 parallax art for a cherry tree, a circuit board or a train window barely
exists, which is why those places lean on drawn variants rather than on bad
crops of the wrong picture. They are the most open doors in the mod.

**Want your own in the list?** That is what
[CONTEST.md](CONTEST.md) is for: one pull request, one wallpaper, your name in
the menu next to it. The check on the pull request measures your layers and
tells you which of them the box will let move.

The GEN3 BOX ones are drawn procedurally in `main.lua` — no files, no
imports. Everything else is real pixel art, in **the artist's own colours**:
CLASSIC shows it whole, GRID BIG shows the same file at twice the size, and
neither one repaints it. What is done to a pack is mechanical and is stated
in `THIRD_PARTY_NOTICES.md`, along with each item's licence — CC0 or CC BY.

**Only what loops, moves.** Each wallpaper is a stack of layers, and whether a
layer scrolls is measured rather than guessed: the mean difference between its
first and last columns says whether it continues into itself. Clouds, water,
mist and stars loop, so they drift at their own speeds; buildings, mountains
and rock do not, so they hold still. Sliding a picture that does not continue
into itself drags a visible seam across the box every few seconds, which is
worse than not moving at all.

Want your own in here? `CONTEST.md` says how, and the answer is short: a pull
request, CC0 or CC BY, and the check tells you in a minute whether your layers
can scroll.

Names and wallpapers are saved with the save file, so they travel between
screens. A save written before 1.10.0 still reads: a bare scene name means
that scene, drawn here.

## PLACE CRY

When a Pokémon lands in a slot — dropped into an empty cell, swapped in, or
shelved with B — its cry plays. Turn `PLACE CRY` off in the options if you do
not want it. A refused landing (full box, full party, nowhere to go) plays no
cry, because nothing landed.

## Two design notes

**The grid is drawn from battle pics, not icons.** Gen 3's grid works
because every species has its own icon. Gen 1 has no such thing — the icon
table maps a species to one of a handful of shapes (GRASS, MON, WATER, BUG)
and the whole game carries four icon images. Twenty identical blobs in a
grid is strictly worse than the vanilla list of twenty names, so the grid
draws each Pokémon's `spriteFront` at exactly half scale instead. Half is
deliberate: an integer divisor keeps two-bit pixel art crisp where 0.6 would
smear it, and the arithmetic lands — five columns of 28 is 140 across a
160-wide screen, four rows is 112 of the 144 down, leaving a header and a
footer.

Those pictures are read through the engine's `Assets.image`, which is also
the seam a sprite mod shadows — so if you run an animated-sprite mod, its
art shows up in this grid too.

**A box stays a compact array.** Gen 1 stores a box as `box[1..n]` with
nothing after `n`, not Gen 3's sparse grid, and the vanilla PC, the save
format and every other mod read that shape. So dropping into an empty cell
appends to the end rather than leaving a hole. It is the one thing here that
is not a faithful copy of Ruby, and the price of a save the rest of the game
still understands.

## What it will not do

- It will never empty your party — the last Pokémon cannot be picked up,
  exactly as the vanilla PC refuses it.
- It will never overflow a box past 20 or a party past 6. If you are
  carrying one and both are full, it refuses to close rather than dropping
  it out of the save.
- It touches nothing but `save.boxes` and `save.party`, which are the
  engine's own storage arrays.

## OW SPRITES

**On by default, and it does nothing at all unless you also have
[Wilds of Kanto](https://github.com/YoDrehDenSwagAuf/overworld-spawn-mod)
(`overworld_wild_spawns`) installed and enabled.**

CLASSIC draws a battle pic at half scale into a 28-pixel cell, which is the
best Gen 1 has on its own: the four generic party icons are unreadable in a
grid, so there was never a third option. Wilds of Kanto builds a per-species
overworld sprite for its wilds and its followers, sized for that mod's own
use — a whole sprite rather than a halved one, and it fits a 28-pixel cell
with room to spare.

With both mods installed, in the `CLASSIC` grid,
every occupied cell in the box and the party pane draws that sprite instead
of the half-scale battle pic, at an integer scale — the same rule a
replaced battle pic already follows. `GRID BIG` is untouched: its cell is
56, a battle pic already draws there at scale 1, and a 16-pixel overworld
sprite would have to be blown up four times to fill it.

This reaches the other mod through the engine's own `mod.find`, never a
manifest dependency, so it stays an optional enhancement rather than a
requirement — nobody without Wilds of Kanto installed is affected by it
existing. Nothing of that mod's art is copied into this repository; this
only ever asks it, at runtime, for a path and draws it, the same seam a
sprite-replacement mod already uses to shadow the battle pics above. If
anything about that call is missing or fails — the mod absent, no sprite
resolved, a black-silhouette fallback, or an error — the cell falls back
silently to the battle picture that has always worked.

**Which of that mod's sprites you get.** It is asked the same way that mod
already draws the icons you see in the vanilla party menu: through its
follower sprite service, which honours whatever **Sprite Style** you picked
over there. Its general `spriteProviders` seam is tried second, so the
feature survives if that party-menu path ever goes away.

**On by default** because it cannot change anything for anyone who does not
have Wilds of Kanto installed — without it the whole feature is one `nil`
check and the battle pic. If it ever misbehaves against a future release of
that mod, turning it off restores exactly the old drawing.

## Ideas, and help building them

**Got an idea for something this should do?** Open an issue — there is a
template for it. You do not need to know any Lua, and you do not need to
have worked out how it would be built. Describe what you want and why.

**Want to build it yourself?** Open a pull request. Collaboration is welcome
on any part of this.

Anything you send that includes art has to be your own work — nothing
traced, edited or recoloured from a ROM, a fan game, a wiki or another mod.

## Requirements and legal

This mod is Lua source only. It contains **no ROM, no ROM-derived data, and
no game assets** — `modkit lint` reports `no ROM-derived content`, and the
sprites in the grid are read at runtime from the cache the engine builds
from *your own* legally obtained cartridge dump. Nothing is redistributed
here.

You need Gen1Recomp and your own legally obtained Pokémon Red or Blue ROM.
Neither is provided by this repository, and no help obtaining one will be
given.

Not affiliated with, endorsed by, or connected to Nintendo, Game Freak, or
The Pokémon Company. Pokémon and all related names are trademarks of their
respective owners, used here only to describe what this software does.

## Support

If this saved you some scrolling, you can support the author here:
<https://linktr.ee/made_in_taly>

## Licence

[MIT](LICENSE) — see the file for terms.
