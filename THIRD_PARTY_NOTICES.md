# Third party notices

Every wallpaper in this mod is either drawn here in code, or is pixel art by
somebody else shipped under a licence that allows it. The artist's name is
not buried in this file: it is the label you scroll through in the WALLPAPER
menu, next to the place they drew — `FOREST < ANSIMUZ >`. Credit where the
player can see it seemed better than credit where only a lawyer would look.

The art ships as the artist made it, at their own resolution and in their own
colours. Nothing is repainted: the box shows it whole on the CLASSIC grid,
and on GRID BIG the engine's own palette pass flattens it to the four tones
that layout uses, the same way it treats everything else on that screen.

## Public domain (CC0 1.0) — no conditions

- **ansimuz** (Luis Zuno) — *Parallax Forest / Warped* art, used for
  `FOREST < ANSIMUZ >`. https://opengameart.org/content/forest-background
- **MatiasVME** — *Parallax background forest pixel art*, used for
  `FOREST < MATIASVME >`.
  https://opengameart.org/content/parallax-background-forest-pixel-art
- **Yevhen Babiichuk (DustDFG)** — *Pixel Art Mountains Parallax*, used for
  `SKY < DUSTDFG >`.
  https://opengameart.org/content/pixel-art-mountains-parallax
- **FabinhoSC** — *Background Clouds And Mountains Parallax*, used for
  `SKY < FABINHOSC >`.
  https://opengameart.org/content/background-clouds-and-mountains-parallax
- **FabinhoSC** — *Skyline Background*, used for `CITY < FABINHOSC >`.
  https://opengameart.org/content/skyline-background
- **Scribe** — *Underwater Scene (Loopable)*, used for `SEA < SCRIBE >`.
  https://opengameart.org/content/underwater-scene-loopable
- **leyren** — *Stars/Space Background*, used for `NIGHT < LEYREN >`.
  https://opengameart.org/content/starsspace-background

CC0 asks for nothing at all. These credits are here because taking someone's
work without saying whose it is would be shabby, not because it is required.

## Attribution (CC BY 4.0) — credit required

- **Admurin** — *Parallax Backgrounds* (Snowy Mountains, Caves), used for
  `SNOW < ADMURIN >` and `CAVE < ADMURIN >`.
  https://opengameart.org/content/parallax-backgrounds
  Licensed under Creative Commons Attribution 4.0 International:
  https://creativecommons.org/licenses/by/4.0/

These two are the only ones that carry an obligation. It is met three times
over: here, in the README, and in the menu itself.

## Drawn in this repository

Every wallpaper labelled `GEN3 BOX` — the default for each category, and the
whole of SEA, NIGHT and 90S — is drawn procedurally in `main.lua`. No files,
no imports, nobody else's pixels: shapes, palettes and motion written out in
Lua and rendered at runtime. They can be previewed without a ROM through
`tests/_render.lua`, which stubs `love.graphics` and writes the frames out.
