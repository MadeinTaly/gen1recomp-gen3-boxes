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

- **320 x 144**, or a stack of layers at that size
- any number of colours: the box shows it whole on CLASSIC, and GRID BIG
  flattens it to four tones through the engine's own palette pass
- layers are better than one picture. Split what loops from what does not:
  clouds, water, mist and stars loop; buildings, mountains and rock do not

## What the check does

CI measures each layer's **seam** — the mean difference between its first and
last column — and decides from that whether the layer may scroll. Cyclic
layers get motion; painted ones are held still, because sliding a picture
that does not continue into itself drags a visible join across the box every
few seconds. You get the verdict on the PR in a minute, and it is a
measurement rather than an opinion.

## Voting

A GitHub Discussion poll per round. Each entry is posted twice: **the scene
alone, and the scene with the grid over it.** The second one is what decides
it — a beautiful wallpaper that swallows twenty sprites is a bad wallpaper,
and that is only visible with the Pokémon on top.

## The shelf

Each category holds a fixed number of wallpapers. When a new one wins, the
one with the fewest votes that round leaves the shipped set — it stays in the
repository and in `THIRD_PARTY_NOTICES.md`, it just is not in the zip. There
is no vote to remove anybody's work: the shelf is simply full.
