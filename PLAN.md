# 1.6.0 — the plan

Five features, agreed up front: **FIND + JUMP**, **SORT**, **MARKS**,
**BOX NAMES + WALLPAPERS**, and **a cry when a Pokémon is put down**
(switchable off in the options). Everything ships tested, and the packed
`.zip` is handed over before anything is published.

This file is the working plan for that release. It is written against the
engine as it actually is: every API named below was read in
`bryanthaboi/gen1recomp` before it was planned against, and the notes say
where.

## What the engine already gives us

Checked, not assumed:

| Need | What exists | Where |
| --- | --- | --- |
| A menu over the box screen | `mod.ui.ListMenu` — `isOpaque = true` | `src/ui/ListMenu.lua` |
| Typing a box name | `mod.ui.NamingScreen` — pops itself, then `onDone(name)` | `src/ui/NamingScreen.lua` |
| State that travels with the save | `mod.save:get/set` (backed by `save.modData`) | `src/mods/Loader.lua:922` |
| Per-Pokémon data that survives a save | any data-only field on the mon; the writer serializes whole tables | `src/core/SaveSerializer.lua`, `docs/modding.md:271` |
| A cry | `Sound.playCry(game.data, species)` — returns `nil` headless, so it is safe in tests | `src/core/Sound.lua:561` |
| Wallpaper colours | `PaletteFX.zone(colors, …)` takes a plain 4×`{r,g,b}` table | `src/render/PaletteFX.lua:219` |
| Species sort keys | `def.dex`, `def.name`, `def.types` | `tests/fixture_data/pokemon.lua` |

Two consequences that shape the design:

**Menus must be opaque.** `Game:draw` asks the **top** state for its surface
(`src/core/Game.lua:474`). A non-opaque widget — `Menu`, `ChoiceBox`,
`QuantityBox` — has no `uiSize`, so the canvas drops to 160×144 while the
`BIG` screen underneath still draws at 320×288 and is cut in half. Every
menu this release adds is a `ListMenu` or a `NamingScreen`, both of which
are opaque and hide the box screen entirely. The one panel that is *not*
opaque — the marking window — is drawn by the box screen itself, in the box
screen's own layout, which is exactly why it cannot be a `ChoiceBox`.

**Wallpaper colours are ours, not the ROM's.** The four-colour tables are
authored in `main.lua`. No ROM-derived palette is copied, so
`modkit lint`'s `no ROM-derived content` still holds.

## The control scheme

Nothing that works today changes meaning. The new surface is a **header
row**, which is where Gen 3 puts it: the cursor rises out of the grid onto
the box title.

| Where | Key | Action |
| --- | --- | --- |
| grid, top row | UP | onto the header |
| header | LEFT / RIGHT | change box |
| header | DOWN | back into the grid |
| header | UP | to the bottom row (`CURSOR WRAP` on) or stay |
| header | **A** | the **BOX MENU** |
| header | **START** | **FIND NEXT**, when a search is active |
| header | B | back, exactly as everywhere else |
| grid, mark mode | **A** | open the marking window on this Pokémon |
| grid, mark mode | B | leave mark mode (a back, before the exit) |
| marking window | LEFT / RIGHT, A, B | pick a symbol, toggle it, close |

`A`, `B`, `START` and `SELECT` keep every meaning they have in 1.5.2 — B is
still back and only back, START over a Pokémon is still its summary. The
header is reached by walking to it, so no binding is spent on it.

**One deliberate change:** with `CURSOR WRAP` on, UP from the top row used
to wrap to the bottom. It now stops on the header, and UP again wraps to the
bottom. The wrap is not lost, it gains a stop — and it is the stop the whole
release hangs off.

## The BOX MENU

A `ListMenu`, titled with the box's name.

```
FIND            → SPECIES (naming screen) / TYPE (list) / MARK (list)
FIND NEXT       → only present while a search is active
SORT            → BY DEX / BY LEVEL / BY NAME / BY TYPE / UNDO
JUMP TO BOX     → the twelve boxes, each with its name and n/20
NAME BOX        → the naming screen, 8 glyphs
WALLPAPER       → the wallpaper list
MARK MODE       → on / off
CANCEL
```

Submenus close their parent on the way to acting (`sub:close()` then
`parent:close()`), so a choice always lands back on the grid and B from a
submenu returns to the box menu.

## The five features

### 1. FIND, and JUMP TO BOX

The problem this exists for: Gen 1 gives you 240 slots and no way to look
into them. `FIND` searches **every box**, from the cursor forward, wrapping
back around to where it started:

- **SPECIES** — the naming screen; a substring match against the nickname,
  the species name and the raw species id, so `CHAR` finds CHARMANDER and a
  Pokémon nicknamed CHARLIE alike.
- **TYPE** — the list is built from `game.data.pokemon`, deduped and sorted,
  so a species-adding mod's types appear without being named here.
- **MARK** — the four symbols, by word (`CIRCLE`, `SQUARE`, `TRIANGLE`,
  `HEART`), because the font has no glyph for `●`.

A hit sets `currentBox`, `col` and `row` and reports the name in the footer;
a miss says so and moves nothing. The query is remembered, and **START on
the header** is FIND NEXT — the header is the one place START has nothing to
show a summary of, so it costs no binding.

The **party is not searched**. It is six visible slots on the same screen;
searching it would be answering a question nobody has.

`JUMP TO BOX` is the same list `BoxMenu.changeBox` shows — `*BOX 3` and
`12/20` — without the vanilla PC's save prompt, because this screen writes
no save.

### 2. SORT

`BY DEX` (`def.dex`), `BY LEVEL` (descending — the strongest first is what
anyone sorting a box wants), `BY NAME`, `BY TYPE` (first type, then dex).
Every comparison falls back to the current index, so the sort is **stable**
and a box of equal keys is not reshuffled.

Sorting rewrites the array in place. It stays compact, so the vanilla PC and
the save format read it exactly as before.

**UNDO** keeps one snapshot, for the current box, for as long as the screen
is open. It refuses when the box has changed since — the check is that the
snapshot is a permutation of what is in the box now, by table identity, so
undo can never resurrect a Pokémon that was moved away or drop one that
arrived. A refusal says `CAN'T UNDO NOW.` and does nothing.

### 3. MARKS

Gen 3's `● ■ ▲ ♥`, stored on the Pokémon as `mon.gen3Marks`, a four-character
string of `0`/`1`. A plain string rather than a table: it costs four bytes in
the save, it reads as one value in a save dump, and it cannot half-exist the
way a sparse array of booleans can.

They are drawn as small filled shapes in the bottom-left of the cell — real
`love.graphics` primitives, not glyphs, because the Gen 1 font has none —
over a white pad so they stay legible against a pic. Only the marks that are
set are drawn, as in Gen 3's own box view.

Setting them needs a per-Pokémon entry point, and A, B, START and SELECT are
all spoken for. So marking is a **cursor mode**, which is what Emerald does:
`MARK MODE` in the box menu, then A on a Pokémon opens the window, and B
leaves the mode. The footer says `MARK` for as long as the mode is on, so
there is no state you can be in without being told.

The marking window is drawn by the box screen (it must survive `BIG`), on a
**tile-aligned rect**, and while it is open `sgbPalettes` appends a `GRAYS`
zone over exactly that rect. Later zones draw over earlier ones, so the
window comes out in clean greys instead of wearing whichever species'
palette it happens to cover.

### 4. BOX NAMES and WALLPAPERS

**Names**: the engine's own naming screen, 8 glyphs, defaulting to the
current name. An empty confirm, or the name `BOX n`, stores nothing and the
box goes back to being numbered. Names live in `mod.save` under `boxNames`,
keyed by box number, and reads tolerate string keys in case a save has been
through a converter.

**Wallpapers**: each is a **pattern** and a **four-colour palette**,
per box, in `mod.save` under `boxPapers`.

- The pattern (`PLAIN`, `STRIPES`, `CHECKS`, `DOTS`, `WAVES`) is drawn
  behind the cells at low alpha in **both** layouts, before anything else.
- The palette replaces the base zone `sgbPalettes` already emits, so it
  tints the whole surface — which is what `SummaryMenu` does with its
  whole-screen palette, and the reason the header and footer keep working.
  `CLASSIC` gets the pattern and not the colour, for the same reason it gets
  no per-species palettes: a 28-pixel cell is three and a half tiles.
- `NIGHT` is a palette in reverse — dark where the greys are light. White
  background maps to the dark end and black text to the light end, so it is
  a real dark mode rather than a tint, and it costs nothing but the table.

The default is `PLAIN` with the greys, which is pixel-for-pixel what 1.5.2
draws. Nobody's screen changes until they change it.

### 5. THE CRY ON PUT-DOWN

`PLACE CRY`, a toggle, **on** by default. Every landing plays the cry of the
Pokémon that landed: a drop into an empty slot, the one you put down in a
swap, and the shelving that B does. A refused placement — full box, full
party, no room anywhere — plays nothing, because nothing landed.

It is on by default because it changes nothing but sound, which is the line
`BOX HEALS` is on the wrong side of.

## One bug to fix on the way past

The vanilla PC calls `Stats.ensure(game.data.pokemon[mon.species], mon)`
when a Pokémon leaves a box for the party (`src/ui/BoxMenu.lua:85`). It has
to: `box_struct` carries no stat block, so a mon decoded out of an imported
`.sav` reaches the party menu with `mon.stats` nil and the HP bar
nil-indexes it. **This screen never calls it.** Every path that puts a
Pokémon into `save.party` — `place`, `stow` — will, guarded, and a test
covers a stat-less box mon withdrawn into the party.

## The tests

Extended in `tests/gen3_box_test.lua`; the suite stays the standalone
LuaJIT run CI already does. `fakeGame`'s stack becomes a real miniature
stack (`push` / `pop` / `top`) so menus can be pushed, found by label and
driven through `onChoose` without a graphics context.

- **header** — UP from the top row lands on it; LEFT/RIGHT change box from
  it; DOWN returns; A pushes a menu; nothing is "selected" while on it, so
  START opens no summary.
- **find** — a match in another box moves `currentBox` and the cursor to it;
  a miss moves nothing; FIND NEXT walks to the second match and wraps back
  to the first; type and mark searches match the right Pokémon.
- **sort** — each key orders a scrambled box correctly; the sort is stable;
  the box stays compact and keeps every Pokémon it had; UNDO restores the
  order; UNDO refuses after the box has changed.
- **marks** — the mode gate (A grabs with it off, opens the window with it
  on); toggling writes `gen3Marks`; the value survives a serialize/decode
  round-trip through `SaveSerializer`; the window's zone is tile-aligned and
  drawn last.
- **names / wallpapers** — a name reaches the header and `mod.save`; an
  empty name falls back to `BOX n`; the wallpaper changes the base zone's
  colours and only that; `PLAIN` still emits exactly what 1.5.2 emitted.
- **cry** — `Sound.playCry` is stubbed and counted: one call per landing,
  none on a refusal, none with `PLACE CRY` off.
- **stats** — a box mon with no `stats` gains one when it reaches the party.
- **the existing invariants**, unchanged and re-run in the new states: no
  drawn line runs off the surface or onto the grid (now also on the header,
  in mark mode, and with the marking window open); no two palette zones
  overlap except the marking window's, which must; the party is never
  emptied; no box passes twenty; a carried Pokémon is never dropped out of
  the save.

Run locally exactly as CI does:

```
luajit mods/gen3_box/tests/gen3_box_test.lua      # from the engine root,
                                                   # POKEPORT_DATA_DIR=tests/fixture_data
```

## Order of work

1. `Stats.ensure` on every party landing, plus its test. Smallest, and it is
   a bug.
2. The header row and the box menu skeleton. Everything else hangs off it.
3. `JUMP TO BOX`, then `SORT` + `UNDO`.
4. `FIND` and `FIND NEXT`.
5. `MARKS`: storage, the pips, the mode, the window, the window's zone.
6. `NAME BOX`, then `WALLPAPER` (patterns first, palettes second).
7. `PLACE CRY`.
8. README (controls, options, a section per feature), CHANGELOG 1.6.0,
   `manifest.json` to 1.6.0 and its `description`.
9. `modkit validate --strict`, `lint`, `pack`, full suite green.

## Shipping

Committed and pushed to `claude/mod-interesting-features-r8z1or` as the work
lands. The release only ever happens off `main` — `.github/workflows/release.yml`
runs on a push there and stops on its own if the manifest's version already
has a release — so nothing publishes from this branch.

**The packed `gen3_box-1.6.0.zip` is handed over for approval before any of
this reaches `main`.**
