# Wallpaper contest

One theme per round. Five entries. A week to vote. The winner ships in the
next release, and the artist's name goes in the menu next to their work —
`FOREST < YOURNAME >` — which is where credit actually gets read.

## Entering

Open a pull request adding your art to `assets/wallpapers/` and a row to the
style table in `main.lua`. The PR template asks for the only three things
that matter: **who made it, under what licence, and where it came from.**
Only CC0 and CC BY are accepted. Without that line the PR does not merge —
not pedantry, it is what keeps the mod distributable.

## What the art has to be

- **144 pixels tall.** The width is yours: 160 is one CLASSIC screen and
  shows a whole scene at once, 320 or 512 is a strip that scrolls past. The
  check enforces the height and nothing else
- any number of colours, and they are the colours the player sees: CLASSIC
  shows the art whole, GRID BIG shows it at twice the size, neither one
  repaints it
- a painted layer does not sit dead: the box pans slowly across whatever
  width it has spare, and turns back before the join could show. Mark a
  layer `still` in the style table if it must not move at all
- layers are better than one picture. Split what loops from what does not:
  clouds, water, mist and stars loop; buildings, mountains and rock do not

## What the check does

CI measures each layer's **seam** — the mean difference between its first and
last column — and decides from that whether the layer may scroll. Cyclic
layers get motion; painted ones are held still, because sliding a picture
that does not continue into itself drags a visible join across the box every
few seconds. You get the verdict on the PR in a minute, and it is a
measurement rather than an opinion.

## Who decides, and how

**There is no deadline and no round to wait for.** Entries are taken as they
arrive. Open the pull request when the art is ready; if it is good and the
licence line is there, it is merged and it ships in the next release with
your name on it.

**The check is automatic. The decision is not.** CI measures your layers and
says what the box will do with them — it never says whether the art is any
good, and it cannot merge anything. The repository owner
([@MadeinTaly](https://github.com/MadeinTaly)) merges, and that is the whole
approval process today.

**Two things get an entry turned down**, and both are avoidable:

- a licence that is not CC0 or CC BY, or a source that cannot be checked;
- art that swallows the grid. This is the one people are surprised by: a
  wallpaper is looked at **with twenty Pokémon on top of it**, and something
  gorgeous that hides them is a bad wallpaper. Busy in the corners, quiet
  behind the cells.

If something is close but not there, the pull request says so and stays open
rather than being closed. Nobody's work is thrown away for being early.

**Voting exists for when there is a crowd**, and only then: if more entries
arrive for one scene than the shelf holds, they go up as comments on the
[contest issue](../../issues/6) — the scene alone, and the scene with the
grid over it — and thumbs on those comments decide it. Ties are broken by
the owner. Until that happens, "does it look good with Pokémon on it and is
the licence clean" is the whole bar.

## The shelf

Each scene holds at most ten wallpapers, and none holds fewer than five. When
a scene is full and something better arrives, the weakest entry leaves the
shipped set — it stays in the repository and in `THIRD_PARTY_NOTICES.md`, it
just is not in the zip. There is no vote to remove anybody's work: the shelf
is simply full. A scene that is not full yet takes everything that clears the
bar.
