# Third party notices

Every wallpaper in this mod is either drawn here in code, or is pixel art by
somebody else shipped under a licence that allows it. The artist's name is
not buried in this file: it is the label you scroll through in the WALLPAPER
menu, next to the place they drew — `FOREST < ANSIMUZ >`. Credit where the
player can see it seemed better than credit where only a lawyer would look.

**These are adaptations, and CC BY asks that changes be stated.** Nothing is
repainted and no pixel is anybody else's work but the artist's — what is
done to each pack is mechanical, and it is the same three things every time:

- the parallax layers are separated into what may scroll and what must hold
  still, measured by whether a layer's right edge continues into its left;
- the art is brought to the 144-pixel height of the box, by scale where a
  pack is drawn larger than that (MatiasVME's forest is drawn at 1280x360
  and is reduced by two and a half) and at its own scale where it is not
  (DustDFG's valley is drawn at 160x80 and ships at 1:1);
- colours are reduced where the reduction leaves the scene intact.

On screen it is then shown as drawn: whole on the CLASSIC grid, and at twice
the size on GRID BIG, in the artist's own colours. Before 1.10.2 GRID BIG
flattened all of it to four tones of the box palette, which was a bug and not
a house style.

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

Every wallpaper labelled `GEN3 BOX` — the first entry of every category, and
the only entry 90S has — is drawn procedurally in `main.lua`. No files, no
imports, nobody else's pixels: shapes, palettes and motion written out in Lua
and rendered at runtime. They can be previewed without a ROM through
`tools/render_wallpapers.lua`, which stubs `love.graphics` and writes the
frames out.
