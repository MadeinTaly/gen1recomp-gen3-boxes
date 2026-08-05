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

Requires Gen1Recomp with mod API 2 (engine 0.1.37 or newer).

## Controls

| Key | Action |
| --- | --- |
| D-pad | move the cursor; stepping off the left or right edge changes box |
| **A** | pick up / put down — on an occupied slot the two **swap** |
| **START** | the summary of whatever the cursor is on |
| **B** | back: carrying one it goes back on a shelf first, otherwise close |
| **SELECT** | cross to the party and back — this is how you deposit and withdraw |

B means back and only back, the convention every other screen in this game
follows — and that is what frees START to be the summary. There is no cell
where the way out disappears, which an earlier arrangement had to work
around by putting STATS on B and the exit on START.

## Options

**START → MODS → Gen 3 Box → OPTIONS..**

| Row | Values | Meaning |
| --- | --- | --- |
| `OPEN FROM` | `START+PC` / `START` / `PC` | where the BOXES entry appears |
| `CURSOR WRAP` | on / off | whether the cursor wraps at the edges |
| `BOX HEALS` | on / off | rest everything in storage when the screen closes |
| `GRID` | `CLASSIC` / `BIG` | a 320×288 surface, full-size pics, and a palette per Pokémon |

`OPEN FROM` is read each time a menu opens, so changing it takes effect
immediately rather than on the next boot.

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
