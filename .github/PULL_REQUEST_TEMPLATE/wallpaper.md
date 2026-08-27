---
name: Wallpaper entry
about: Add a wallpaper to the box
---

## Who made it

- **Artist:**
- **Where it came from:** <!-- link to the original page -->
- **Licence:** <!-- CC0 or CC BY only -->

- [ ] I made this, or it is CC0 / CC BY and I have linked the source
- [ ] The artist's name above is the one that should appear in the menu

Nothing else here matters as much as these three lines. Without them the pull
request cannot be merged — not pedantry: it is what keeps the mod
distributable, and what puts your name in front of the player.

## What it is

- **Scene:** <!-- SEA, FOREST, SKY, CAVE, CITY, SNOW, NIGHT, 90S, or a new one -->
- **Files:** <!-- one image, or a stack: _base / _far / _near -->

## Before you open this

- 144 pixels tall; the width is yours (160 is one CLASSIC screen, 320 or
  512 is a strip that scrolls past). The check enforces the height only
- any number of colours, shown as you drew them: CLASSIC shows the art
  whole, GRID BIG shows it at twice the size
- if you can, split what loops from what does not — clouds and water in their
  own layer, buildings and rock in another. The check below measures each
  layer and decides which may scroll

The check runs on this pull request and reports the seam of every layer, its
size and its colour count. It is a measurement, not a review: it tells you
what will move and what will hold still, and you will have it within a minute
of opening this.
