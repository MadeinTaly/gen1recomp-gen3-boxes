-- Gen 3 Box
--
-- A Ruby/Sapphire-style storage screen over Gen 1's twelve boxes of twenty:
-- a grid you can see, a cursor that picks a Pokemon up and puts it down,
-- and one button between the box and your party.
--
-- ------- why the grid is drawn from battle pics
--
-- Gen 3's grid works because every species has its own icon. Gen 1 has no
-- such thing: the icon table maps a species to one of a handful of shapes
-- -- GRASS, MON, WATER, BUG -- and the whole game carries four icon
-- images. Twenty identical blobs in a grid is strictly worse than the
-- vanilla list of twenty names, so the grid is drawn from the `spriteFront`
-- field instead: 154 per-species pictures already decoded out of the ROM.
--
-- They are 40x40 or 56x56, and the cell is 28x28, so they draw at exactly
-- half scale. Half is deliberate -- an integer divisor keeps two-bit pixel
-- art crisp, where 0.6 would smear it -- and it makes the arithmetic land:
-- five columns of 28 is 140 across a 160-wide screen, four rows is 112 of
-- the 144 down, leaving a header and a footer.
--
-- ------- what a slot means
--
-- Gen 1 stores a box as a COMPACT array (src/pokemon/Boxes.lua), not Gen
-- 3's sparse grid: box[1..n] with nothing after n. This screen keeps it
-- that way, because the vanilla PC, the save format and every other mod
-- read that shape. So dropping into any empty cell appends to the end
-- rather than leaving a hole -- the one place this is not a faithful copy
-- of Ruby, and the price of a save the rest of the game still understands.

local COLS, ROWS = 5, 4
local PARTY_COLS, PARTY_ROWS = 3, 2

-- ------- the two layouts
--
-- CLASSIC is the 160x144 Game Boy screen: a 28-pixel cell with the pic at
-- half scale, which is what every version up to 1.4.0 drew.
--
-- BIG asks the renderer for a 320x288 surface. The engine offers this
-- properly: `Game:draw` calls `Renderer:setUISize(top:uiSize())` before
-- anything draws, and falls back to 160x144 the moment this screen is not
-- on top -- so there is nothing to restore and no way to leave the game
-- wearing a canvas it did not ask for.
--
-- 56 is the number that makes BIG worth having, twice over:
--
--   * a battle pic is 56x56, so it is drawn at scale 1. Not enlarged, not
--     shrunk -- every pixel of the sprite is one pixel of the canvas, the
--     first time this screen has shown one undamaged.
--   * 56 is SEVEN TILES exactly, and a palette zone is addressed in
--     tiles. A 28-pixel cell is three and a half, which cannot carry a
--     zone at all. That is the whole reason the colours below are only
--     possible in this mode.
local LAYOUT = {
  classic = { cell = 28, gridX = 10, gridY = 16, partyX = 38, partyY = 40,
              scale = 0.5, w = 160, h = 144 },
  -- gridX 16 rather than 20: 5x56 = 280 leaves a 40-pixel margin, and
  -- half of it is not a whole tile. Eight pixels off centre is invisible;
  -- a zone that starts mid-tile is not.
  big     = { cell = 56, gridX = 16, gridY = 32, partyX = 72, partyY = 72,
              scale = 1, w = 320, h = 288 },
}

return function(mod)
  local Boxes = require("src.pokemon.Boxes")
  local Party = require("src.pokemon.Party")
  local Font = require("src.render.Font")
  -- The cursor is a glyph CODE, not a character: ">" is not in the game's
  -- charmap, so a hand-drawn menu that wants the same arrow every other
  -- screen shows has to ask Theme for it and draw it with drawCode.
  local okTheme, Theme = pcall(require, "src.ui.Theme")
  if not okTheme then Theme = nil end
  local Assets = require("src.render.Assets")
  -- The per-instance art seam: Sprites.path raises `pokemon.sprite` with the
  -- live mon in its ctx, which is how a shiny tells itself apart from an
  -- ordinary one of the same species (issue #2).
  local Sprites = require("src.pokemon.Sprites")
  local Screens = require("src.ui.Screens")
  local Strings = require("src.core.Strings")
  local Stats = require("src.pokemon.Stats")
  local Sound = require("src.core.Sound")

  local SCREEN = "Gen3Box"

  -- ------- which generation is running
  --
  -- Resolved fresh every call, off the live game -- never cached at file
  -- scope and never a version allow-list (docs/mod-api-gen2-compat.md's
  -- "what the facades cannot fix", and modkit's own MK409 check exists to
  -- catch exactly that shape). A Gen 2 save carries `generation` once it
  -- exists (src/core/gen2/Save.lua:344); before that -- a save mid
  -- construction, or a headless test harness with no save at all --
  -- GameVersion.generation() is asked instead, itself pcall'd because this
  -- file is required by the SDK test harness outside a booted game too.
  local function isGen2(game)
    local save = game and game.save
    if save and save.generation ~= nil then
      return save.generation == 2
    end
    local ok, generation = pcall(function()
      return require("src.core.GameVersion").generation()
    end)
    return ok and generation == 2
  end

  -- modkit's MK409 check flags this pair as a hardcoded Gen 1 screen id;
  -- false positive here, since isGen2(game) below is the real branch.
  local SCREEN_SUMMARY_GEN1 = "SummaryMenu"
  local SCREEN_SUMMARY_GEN2 = "Gen2SummaryMenu"

  -- Only what is actually honoured below. The vanilla box PC is left in
  -- place whichever way this is set: nothing is taken away, and turning the
  -- mod off leaves a save reaching its storage exactly as before.
  --
  -- A row that cannot do anything on this boot is not shown on it. GRID is
  -- the only one: layout() reads CLASSIC on Gold whatever the option says,
  -- because Game2:draw has no uiSize seam for BIG to ask through. It used
  -- to be listed with "(GEN 1 ONLY)" bolted onto its label, which is a
  -- menu row that exists to explain why it does nothing. isGen2(nil) reads
  -- the SAME generation layout() reads at draw time, once, while the schema
  -- is built -- and define() runs once per boot, so a Red boot still gets
  -- the row. The option itself is never written back either way, so a save
  -- that chose BIG on Red is still BIG the next time it is Red.
  local schema = {
    { key = "access", label = "OPEN FROM", type = "choice", default = "both",
      choices = {
        { "START+PC", "both" },
        { "START", "start" },
        { "PC", "pc" },
      } },
    { key = "wrap", label = "CURSOR WRAP", type = "toggle", default = true },
    -- See "the box as a nurse" below. Off by default because it is free
    -- healing, and free healing is an economy change rather than a
    -- convenience: it is Potions and Centre trips that stop being needed,
    -- not clicks that stop being clicked.
    { key = "heal", label = "BOX HEALS", type = "toggle", default = false },
    -- See "the two layouts" above. CLASSIC is what 1.4.0 drew. On a Gold
    -- boot this row is taken out below rather than shown as a choice that
    -- quietly does nothing.
    { key = "grid", label = "GRID", type = "choice", default = "classic",
      gen1Only = true,
      choices = {
        { "CLASSIC", "classic" },
        { "BIG", "big" },
      } },
    -- FULL SCREEN takes the whole device instead of a Game Boy screen, and
    -- spends the room on MORE BOXES rather than on bigger ones: as many
    -- 5x4 panels as fit, across first and then down, each with its own name
    -- and its own wallpaper. The cursor walks between them.
    --
    -- It sits BESIDE grid rather than overriding it: GRID picks the size
    -- of a cell, and that question has two answers on any surface -- see
    -- fullCell(). Overriding it was reported as the setting being broken.
    -- The WIP came off when the three things that earned it were done: the
    -- BOX MENU opens from every panel's own name, FIND and JUMP TO BOX
    -- bring their box onto the screen and under the cursor, and the party
    -- pane is centred on this surface with the box's scene behind it.
    -- ON by default from 1.23.0: the grid is what this mod is, and on a
    -- phone the Game Boy letterbox spends most of the glass on nothing.
    -- OPTIONS puts it back.
    { key = "fullscreen", label = "FULL SCREEN", type = "toggle",
      default = true },
    -- TOUCH is off by default and, while it is off, this screen is exactly
    -- the screen it was: the hook returns before it looks at anything, so
    -- the grid keeps whatever shape GRID was set to and no finger can move
    -- it. That is the whole of "touch disabled means standard".
    --
    -- Two fingers drive the GRID setting rather than a zoom of their own:
    -- this grid has two cell sizes and already has a setting that picks
    -- between them, so the change sticks after you leave and there is no
    -- second, hidden zoom to reconcile with the first.
    -- ON by default from 1.23.0 as well: this is played on phones, and a
    -- d-pad drawn over glass is not how anybody reaches for a box. Turning
    -- it off restores the buttons-only screen exactly.
    { key = "touch", label = "TOUCH", type = "toggle", default = true },
    -- The neighbours, sliced by the screen edge, the way Pokemon Box on the
    -- GameCube draws them. It is what makes storage read as a shelf you are
    -- standing in front of rather than a page you are turning: you can see
    -- that there is a box that way before you walk into it.
    --
    -- On by default in BIG, where the grid leaves a 16-pixel margin to draw
    -- it in; CLASSIC leaves 10, which is a sliver, so it is a choice rather
    -- than an assumption.
    { key = "peek", label = "PEEK NEXT BOX", type = "toggle", default = true },
    -- See "the cry on put-down" (PLAN.md "5. THE CRY ON PUT-DOWN"). On by
    -- default: it changes nothing but sound, which is the line BOX HEALS
    -- is on the wrong side of.
    { key = "placeCry", label = "PLACE CRY", type = "toggle", default = true },
    -- See "overworld sprites from Wilds of Kanto" below. Off by default --
    -- unlike PLACE CRY, this is an experimental prerelease feature reaching
    -- into another mod's code, not a change to this mod's own behaviour,
    -- and it does nothing at all unless that mod is installed.
    { key = "owSprites", label = "OW SPRITES", type = "toggle", default = true },
    -- The wallpaper drifts instead of sitting still (see
    -- drawWallpaperPattern). On by default, because it is the same rule
    -- PLACE CRY is on the right side of: it changes how the screen LOOKS
    -- and nothing about what it does, and a Gen 3 box wallpaper moves. Off
    -- pins every pattern at phase zero, which is pixel-for-pixel the still
    -- wallpaper 1.6.0 drew -- so anyone who finds motion distracting, or is
    -- sensitive to it, gets the old screen back exactly.
    { key = "animate", label = "ANIMATE", type = "toggle", default = true },
    -- How opaque each slot is over the wallpaper. This is a taste with no
    -- right answer -- how much scene you want behind your Pokemon -- so it
    -- is a row rather than a number picked here on everyone's behalf.
    --
    -- 15% is the default, down from 40 and then 25. Twenty cells at 40%
    -- white is a sheet of milk over the picture -- the grid reads first and
    -- the scene reads as a smudge behind it, which is backwards: the cell
    -- outline is what says "slot", and the wash only has to lift a Pokemon
    -- off a busy patch. CLEAR is the honest end of the ladder: no slot at
    -- all, the wallpaper straight through.
    { key = "slots", label = "SLOTS", type = "choice", default = "15",
      choices = {
        { "CLEAR", "0" },
        { "10%", "10" },
        { "15%", "15" },
        { "25%", "25" },
        { "40%", "40" },
        { "60%", "60" },
        { "80%", "80" },
      } },
    -- The title row and the footer are painted back to white because they
    -- are black text, and Gen 3 keeps its header on a solid band for the
    -- same reason. But a scene that runs under them instead is the thing
    -- people actually ask for -- the wallpaper taking the WHOLE screen --
    -- and the only real objection is legibility, which is answerable: below
    -- SOLID every caption gets a light halo, so the letters keep an edge
    -- over a night sky the same way they do over a white band.
    -- The bottom of the ladder is 15%, not nothing. A whisper of white is
    -- still the wallpaper edge to edge -- you read the row as scene rather
    -- than as a band -- but it stops the captions from having to fight the
    -- one scene that happens to be exactly their colour. Zero is honoured
    -- if a save carries it; it is simply not offered, because the halo is a
    -- rescue and this is not needing one.
    { key = "bands", label = "BANDS", type = "choice", default = "SOLID",
      choices = {
        { "SOLID", "SOLID" },
        { "60%", "60" },
        { "30%", "30" },
        { "15%", "15" },
      } },
  }

  -- Published twice, and it has to be. At load time the only thing to ask
  -- is the ROM version, which is right on a real boot and is exactly what
  -- layout() will read at draw time. But a game is what really settles it,
  -- so game.ready publishes again with one in hand -- the same seam every
  -- other generation branch in this file goes through, and the only one a
  -- harness can drive. define() replaces the schema and never touches the
  -- stored values, so re-publishing costs a table and changes no setting.
  local function publishOptions(game)
    local rows = {}
    for _, row in ipairs(schema) do
      if not (row.gen1Only and isGen2(game)) then rows[#rows + 1] = row end
    end
    mod.options:define(rows)
  end

  publishOptions(nil)
  mod.events:on("game.ready", function(payload)
    publishOptions(payload and payload.game)
  end)

  -- GRID BIG asks the renderer for a 320x288 surface, and that ask only
  -- ever reaches anything on Gen 1: Game:draw (src/core/Game.lua:471-478)
  -- is what calls `top:uiSize()` and scales the window to fit what comes
  -- back. Game2:draw (src/core/Game2.lua:1334-1450) never does either --
  -- Gold always fits one fixed 160x144 canvas through Chrome.fitScale and
  -- hands every state that same coordinate space -- so a Gold boot honouring
  -- BIG would lay 320x288 of drawing into a canvas built for a quarter of
  -- it. Read here, the one place every consumer (uiSize, cell size, pic
  -- scale, the OW SPRITES gate) goes through layout(), so Gold reads
  -- CLASSIC no matter what the option says. The option itself is left
  -- alone -- never written back -- so a Gen 1 save that chose BIG is still
  -- BIG the next time it is Red.
  -- ------- FULL SCREEN: a surface shaped like the device
  --
  -- The engine takes any surface between 160x144 and 640x576 through
  -- `uiSize()` (Renderer:setUISize clamps to exactly that, falling back to
  -- 160x144 outside it) and letterboxes it onto the window. So "full
  -- screen" is: pick the largest whole-number scale that fits, divide the
  -- window by it, clamp, and hand that back.
  --
  -- Whole-number scale is the point. A surface stretched to the window
  -- exactly would give pixels three rows tall in some places and four in
  -- others, and every wallpaper in this mod is pixel art.
  local MIN_W, MIN_H, MAX_W, MAX_H = 160, 144, 640, 576

  -- A panel is a 5x4 box at the BIG cell, not the classic one.
  --
  -- 56 is the size a battle picture actually is: at 28 the pic is halved,
  -- and a halved Pokemon on a screen this size is the thing to fix rather
  -- than the thing to fit more of. Full screen buys ROOM -- so it is spent
  -- first on the Pokemon being whole and sitting comfortably, and only then
  -- on showing more than one box.
  local FULL_CELL = 56
  -- ...and 28 when GRID says CLASSIC. Full screen used to override GRID
  -- outright, on the reasoning that a surface chosen from the window is
  -- neither of the two fixed layouts. True, and beside the point: what GRID
  -- picks is the SIZE OF A CELL, and that question still has two answers on
  -- any surface. Choosing CLASSIC and getting 56-pixel cells reads as the
  -- setting being broken -- which is exactly how it was reported.
  -- ------- WHICH GRID, AND WHERE THAT CHOICE LIVES
  --
  -- The SAVE first, the option second, because `mod.options` is READ-ONLY:
  -- it has `define` and `get` and nothing else
  -- (src/mods/Loader.lua:1493-1510). `mod.options:set` was a call to a
  -- function that does not exist, swallowed by its own pcall -- which is
  -- why the two-finger pinch appeared to do nothing. `mod.save` is the
  -- writable one, so a pinch lands there and is read back ahead of the
  -- option, and the option stays what a fresh save starts from.
  local function gridChoice()
    local okS, saved = pcall(function() return mod.save:get("grid") end)
    if okS and (saved == "big" or saved == "classic") then return saved end
    local ok, value = pcall(function() return mod.options:get("grid") end)
    return (ok and value) or "classic"
  end

  local function setGridChoice(value)
    if value ~= "big" and value ~= "classic" then return false end
    if gridChoice() == value then return false end
    local ok = pcall(function() mod.save:set("grid", value) end)
    return ok and gridChoice() == value
  end

  local function fullCell()
    return gridChoice() == "classic" and 28 or FULL_CELL
  end

  -- A panel is a 5x4 box at whatever that cell is, plus its own name row.
  local function panelSize(cell)
    return 5 * cell + 8, 4 * cell + 24
  end
  local PANEL_W, PANEL_H = panelSize(FULL_CELL)

  local function fullOn()
    local ok, value = pcall(function() return mod.options:get("fullscreen") end)
    return ok and value == true
  end

  local function windowSize()
    local ok, w, h = pcall(function()
      return love.graphics.getDimensions()
    end)
    if ok and type(w) == "number" and w > 0 and h > 0 then return w, h end
    return MIN_W, MIN_H
  end

  local function fullLayout()
    local ww, wh = windowSize()
    -- Which scale? The SMALLEST whole one that still fits inside what the
    -- engine will take. That is the biggest canvas available, and the
    -- biggest canvas is the most boxes -- which is the whole point.
    --
    -- Two earlier passes got this backwards. The first took the largest
    -- scale that fits, maximising the size of a pixel and minimising how
    -- much of anything you see. The second searched for the scale that fit
    -- the most panels, which is the same answer when the window is measured
    -- in device pixels -- and the wrong one on a phone, where
    -- love.graphics.getDimensions reports LOGICAL units (a 1080-wide screen
    -- at 2.67 dpi reports 405). A reported 405x900 made that search settle
    -- on a 160x300 canvas: five columns, and a Pokedex that looked zoomed
    -- in rather than opened up.
    --
    -- The canvas takes the SHAPE OF THE SCREEN, and the screen is filled.
    --
    -- Two earlier passes chased whole-number scales, on the grounds that a
    -- fractional one makes some pixels a row taller than others. Both left
    -- black bands over a third of a phone's height, and a full screen with
    -- bands is not a full screen -- so the scale is fractional now and
    -- `wantsFillScale` below tells the renderer to blit at it.
    --
    -- The ratio is taken against the CAPS, not against a fixed surface:
    -- divide the window by whichever of 640-wide or 576-tall it busts by
    -- most, and what comes out has the window's own proportions and is as
    -- large as the engine will accept. A 405x900 phone lands on 256x576; the
    -- same phone turned sideways lands on 640x288, which is why the boxes go
    -- four across there and one across in the hand.
    local cell = fullCell()
    local panelW, panelH = panelSize(cell)
    local k = math.max(ww / MAX_W, wh / MAX_H, 1)
    local w = math.max(MIN_W, math.min(MAX_W, math.floor(ww / k)))
    local h = math.max(MIN_H, math.min(MAX_H, math.floor(wh / k)))
    -- one whole panel has to fit across, even on a narrow phone: a canvas
    -- the shape of the screen would be 256 wide there, and a 5x56 box is
    -- 288. Widening past the window shape costs a thin band at the sides
    -- and buys a Pokemon you can see.
    w = math.max(w, math.min(MAX_W, panelW + 8))
    w, h = w - w % 8, h - h % 8
    -- whole tiles, because palette zones are addressed in tiles and a zone
    -- that starts mid-tile lands four pixels off its sprite
    local acrossN = math.max(1, math.floor((w - 8) / panelW))
    local downN = math.max(1, math.floor((h - 20) / panelH))
    return {
      cell = cell, scale = 1, w = w, h = h,
      full = true, acrossN = acrossN, downN = downN,
      panelW = panelW, panelH = panelH,
      -- The first panel's origin; the rest are laid out from it.
      --
      -- BOTH are rounded to a whole tile, and that is not tidiness. The
      -- palette pass refuses to emit a single zone unless every one of
      -- cell, gridX, gridY, partyX and partyY is a multiple of 8 (see
      -- sgbPalettes, and remapOff which repeats the test) -- a zone is
      -- addressed in TILES, so an origin off the tile grid would colour a
      -- rectangle that does not line up with the picture inside it.
      --
      -- `gridY` was 20 and `gridX` carried a `+ 6`, so neither was ever a
      -- multiple of 8 and full screen ALWAYS failed that test. No zones,
      -- and remapOff false as well, which is `species = nil` into paintPic:
      -- every battle pic on the biggest surface this mod offers was drawn
      -- in four DMG greys. It looked like the wallpaper had eaten the
      -- colour. GRID BIG was never affected because its gridY is 32.
      --
      -- Overworld sprites hid it: they are the mod's own colour art, they
      -- never wanted a zone, and a screen full of them looks perfectly
      -- right while every battle pic beside it is grey.
      gridX = math.floor(((w - acrossN * panelW) / 2 + 6) / 8) * 8,
      gridY = 24,
      -- the party grid is PARTY_COLS wide, not six: the first version
      -- centred a six-column block that does not exist and left the six
      -- real cells sitting left of middle
      partyX = math.floor((w - PARTY_COLS * cell) / 2)
        - (math.floor((w - PARTY_COLS * cell) / 2) % 8),
      partyY = math.floor((h - PARTY_ROWS * cell) / 2)
        - (math.floor((h - PARTY_ROWS * cell) / 2) % 8),
    }
  end

  local function layout(game)
    -- FULL SCREEN reaches the renderer through the same uiSize() seam BIG
    -- does, so it is Gen 1 only for exactly the same reason -- Game2 never
    -- asks a state how big it would like to be. On Gold the screen draws
    -- itself over the window instead (drawWidescreen, further down).
    -- FULL SCREEN works on both: Gen 1 asks for the surface through
    -- uiSize(), Gold draws itself over the window through drawWidescreen.
    -- Same layout either way, which is the point of computing it here.
    if fullOn() then return fullLayout() end
    if isGen2(game) then return LAYOUT.classic end
    return LAYOUT[gridChoice()] or LAYOUT.classic
  end

  -- ------- the box as a nurse
  --
  -- BOX HEALS restores what is in storage: full HP, status cleared, every
  -- move's PP back. It is the Pokemon Centre's own routine rather than an
  -- imitation -- `Pokemon.heal` is what engine/events/heal_party.asm
  -- HealParty does, PP-Up bonus included, and the nurse calls that same
  -- function. Storage that quietly healed a differently-shaped amount
  -- would be worse than storage that did not heal at all.
  --
  -- It runs ONCE, when the screen closes, and not on each placement.
  -- Healing per move would have meant deciding what a move even is: a
  -- deposit heals, but a swap is a deposit and a withdrawal at the same
  -- time, and dragging a mon between two box slots is neither. On close
  -- there is no such question -- whatever ended up in storage comes out of
  -- it rested, however it got there.
  --
  -- The party is deliberately left alone. Not to police an exploit -- you
  -- can deposit six and take them back -- but because the party is the
  -- half of this screen that is NOT storage, and a screen that healed your
  -- active six for opening and closing it would be a Centre with extra
  -- steps.
  local Pokemon = require("src.pokemon.Pokemon")

  local function healing()
    local ok, value = pcall(function() return mod.options:get("heal") end)
    return ok and value and true or false
  end

  -- PLACE CRY, on by default (guarded the way every other options read
  -- here is, rather than trusted).
  local function placeCryOn()
    local ok, value = pcall(function() return mod.options:get("placeCry") end)
    if not ok then return true end
    if value == nil then return true end
    return value and true or false
  end

  -- OW SPRITES, guarded the same way. See "overworld sprites from Wilds of
  -- Kanto" further down for what it does and why it defaults off.
  -- The slot opacity the player asked for, 0..1. An unreadable or missing
  -- value falls to the default rather than to invisible: a box whose slots
  -- vanished because an option failed to load would look broken.
  local function slotAlpha()
    local ok, value = pcall(function() return mod.options:get("slots") end)
    if not ok then return 0.15 end
    local n = tonumber(value)
    if not n then return 0.15 end
    return math.max(0, math.min(100, n)) / 100
  end

  -- How opaque the header and footer bands are, 0..1, or nil for SOLID --
  -- which is not the same as 1: solid means the band is painted white and
  -- the captions need nothing else, while 100%% would still turn the halo
  -- on for no reason. An unreadable option falls back to SOLID, because a
  -- caption nobody can read is the one failure worth defaulting away from.
  local function bandAlpha()
    local ok, value = pcall(function() return mod.options:get("bands") end)
    if not ok or value == nil or value == "SOLID" then return nil end
    local n = tonumber(value)
    if not n then return nil end
    return math.max(0, math.min(100, n)) / 100
  end

  -- The colour of those bands. Not white: white is a sticker laid on a
  -- picture, and it is what a player called ugly the first time they saw a
  -- forest under one. Every scene carries four tones and the lightest of
  -- them is a near-white of the scene's own hue -- pale blue under SEA,
  -- cream under CAVE -- so the band reads as part of the painting while
  -- staying light enough to hold black text.
  --
  -- NIGHT is why this looks for the lightest tone rather than taking the
  -- first: its ramp runs backwards, and palette[1] there is nearly black.
  -- If nothing in a scene is light enough, white is the honest answer.
  -- The two tones a caption is written in: one for the letters, one for the
  -- edge around them. Both come out of the SCENE's own four colours rather
  -- than being black and white, which is what makes them sit in the picture
  -- instead of on it -- and which way round they go is decided by the scene:
  -- light letters with a dark edge over a volcano, dark letters with a light
  -- edge over a desert.
  --
  -- This is not sampling the pixels underneath. Reading back a canvas every
  -- frame to average what is behind eight glyphs would cost a GPU round trip
  -- per frame for a decision that changes only when the wallpaper does; the
  -- palette says the same thing for nothing, because the pixels underneath
  -- were painted out of it.
  -- Black, or white when the scene is dark. That is the whole rule.
  --
  -- Two cleverer versions shipped before it: a white plate under each
  -- caption, which read as a sticker, and letters in one end of the scene's
  -- palette with a one-pixel edge in the other, which came out fat and
  -- doubled on a pale sky. Type over a picture wants the plainest thing
  -- that stays legible, and on a four-tone scene that is one flat ink.
  local function captionInk(paper)
    local palette = paper and paper.palette
    if not palette then return nil end
    local total, n = 0, 0
    for i = 1, 4 do
      local c = palette[i]
      if type(c) == "table" and c[1] and c[2] and c[3] then
        total = total + 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
        n = n + 1
      end
    end
    if n == 0 then return nil end
    if total / n < 110 then return { 255, 255, 255 } end
    return { 0, 0, 0 }
  end

  local function bandTint(paper)
    local palette = paper and paper.palette
    if not palette then return nil end
    local best, bestLuma
    for i = 1, 4 do
      local c = palette[i]
      if type(c) == "table" and c[1] and c[2] and c[3] then
        local luma = 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
        if not bestLuma or luma > bestLuma then best, bestLuma = c, luma end
      end
    end
    if best and bestLuma >= 170 then return best end
    return nil
  end

  local function peekOn()
    local ok, value = pcall(function() return mod.options:get("peek") end)
    return ok and value == true
  end

  local function animateOn()
    local ok, value = pcall(function() return mod.options:get("animate") end)
    if not ok then return true end
    return value ~= false
  end

  local function owSpritesOn()
    local ok, value = pcall(function() return mod.options:get("owSprites") end)
    if not ok then return false end
    return value and true or false
  end

  -- Read per call rather than cached, so switching OPEN FROM in the manager
  -- takes effect on the next menu that opens instead of the next boot.
  local function access() return mod.options:get("access") or "both" end
  local function onStart() local a = access() return a == "both" or a == "start" end
  local function onPC() local a = access() return a == "both" or a == "pc" end

  -- ------- data helpers
  --
  -- Everything reads and writes save.boxes / save.party directly. Those two
  -- ARE the storage: Boxes.ensure fills in a missing table on an old save,
  -- and after that a box is a plain array this screen rearranges in place.

  local function boxList(game) return game.save.boxes[game.save.currentBox] end

  local function defOf(game, mon) return game.data.pokemon[mon.species] end

  -- The species record can be missing: a save written while a mod that adds
  -- species was enabled still names them after it is turned off. Falling
  -- back to the raw id shows the player something true instead of taking
  -- the frame down with it.
  local function nameOf(game, mon)
    local def = defOf(game, mon)
    return mon.nickname or (def and def.name) or mon.species or "?"
  end

  -- A box's name. Every caller that wants one goes through here rather than
  -- formatting the number itself (PLAN.md "4. BOX NAMES and WALLPAPERS"), so
  -- NAME BOX only ever had to change this one function. Names live in
  -- mod.save under boxNames, keyed by box number -- but a save that has been
  -- through a converter may hand them back with string keys, so both are
  -- tried before falling back to the plain "BOX n" every box starts as.
  local function boxName(n)
    local names = mod.save:get("boxNames")
    local custom = names and (names[n] or names[tostring(n)])
    if type(custom) == "string" and custom ~= "" then return custom end
    return Strings("BOX %d", n)
  end

  -- ------- wallpapers (PLAN.md "4. BOX NAMES and WALLPAPERS")
  --
  -- Each wallpaper is a pattern (drawn behind the grid) and a four-colour
  -- palette (which replaces the whole-surface GRAYS zone self:sgbPalettes
  -- already emits, the same trick SummaryMenu uses for its own whole-screen
  -- palette). The colour tables below are authored here, plain {r,g,b}
  -- tables -- no ROM-derived palette is copied, which is what keeps
  -- `modkit lint`'s "no ROM-derived content" check passing.
  --
  -- PLAIN carries no palette at all (nil), so self:sgbPalettes falls back
  -- to PaletteFX.GRAYS exactly as it always has: the default draws
  -- pixel-for-pixel what 1.5.2 drew, and nobody's screen changes until they
  -- pick something else.
  --
  -- NIGHT is a palette in reverse rather than a tint: GRAYS lightest-first
  -- (white background, black text) turned end-for-end, so the background
  -- maps to the dark end and the text to the light end -- a real dark mode.
  local WALLPAPERS = {
    -- Gen 3 named its wallpapers after PLACES -- FOREST, CITY, DESERT, SNOW,
    -- BEACH, SEAFLOOR -- rather than after shapes, and that is the whole
    -- difference in feel: you are choosing where the box IS, not which
    -- texture is behind it. These are drawn in code (see drawWallpaper), so
    -- no art is copied from anywhere; the four colours of each are authored
    -- here the same way the old ones were.
    { id = "PLAIN",  pattern = "PLAIN",  palette = nil },
    { id = "SEA",    pattern = "SEA",
      palette = { { 232, 246, 252 }, { 150, 205, 232 }, { 70, 140, 190 }, { 20, 60, 100 } } },
    { id = "FOREST", pattern = "FOREST",
      palette = { { 236, 248, 232 }, { 168, 214, 150 }, { 88, 150, 84 }, { 30, 70, 40 } } },
    { id = "SKY",    pattern = "SKY",
      palette = { { 240, 250, 255 }, { 186, 224, 248 }, { 120, 178, 226 }, { 50, 96, 150 } } },
    { id = "CAVE",   pattern = "CAVE",
      palette = { { 238, 234, 228 }, { 190, 180, 168 }, { 128, 116, 104 }, { 52, 46, 42 } } },
    { id = "CITY",   pattern = "CITY",
      palette = { { 240, 238, 246 }, { 196, 192, 214 }, { 132, 128, 158 }, { 48, 46, 66 } } },
    { id = "SNOW",   pattern = "SNOW",
      palette = { { 250, 252, 255 }, { 216, 230, 244 }, { 158, 184, 212 }, { 70, 96, 130 } } },
    { id = "NIGHT",  pattern = "NIGHT",
      palette = { { 30, 30, 40 }, { 70, 70, 92 }, { 140, 140, 168 }, { 226, 226, 240 } } },
    -- The one wallpaper that is not a place. 1998 is what this whole mod is
    -- about, and 1998 had a look: shapes scattered on a pale ground for no
    -- reason at all, on every folder, cup and school jumper.
    { id = "90S",    pattern = "90S",
      palette = { { 250, 246, 236 }, { 236, 108, 148 }, { 84, 196, 196 }, { 60, 56, 108 } } },
    -- Four more places, and two of them run their ramp backwards the way
    -- NIGHT does: a volcano and deep space are dark rooms, and a palette
    -- that starts light would make them grey rooms instead.
    { id = "DESERT", pattern = "DESERT",
      palette = { { 252, 238, 208 }, { 240, 196, 130 }, { 202, 142, 86 }, { 116, 72, 52 } } },
    { id = "VOLCANO", pattern = "VOLCANO",
      palette = { { 38, 26, 32 }, { 92, 44, 52 }, { 208, 96, 44 }, { 252, 206, 128 } } },
    { id = "SPACE",  pattern = "SPACE",
      palette = { { 14, 12, 30 }, { 54, 46, 96 }, { 128, 118, 196 }, { 238, 238, 255 } } },
    { id = "CASTLE", pattern = "CASTLE",
      palette = { { 236, 234, 240 }, { 178, 176, 192 }, { 112, 112, 132 }, { 44, 46, 60 } } },
    -- The five that were proposed in a list and then never drawn, which is
    -- the worst place for an idea to sit. SAKURA and TRAIN are the two that
    -- are not weather or rock: a tree over water, and the view out of a
    -- window at speed.
    { id = "SAKURA", pattern = "SAKURA",
      palette = { { 255, 244, 248 }, { 250, 202, 220 }, { 214, 126, 164 }, { 92, 60, 84 } } },
    { id = "STORM",  pattern = "STORM",
      palette = { { 226, 230, 238 }, { 150, 160, 180 }, { 84, 94, 118 }, { 34, 38, 52 } } },
    { id = "CIRCUIT", pattern = "CIRCUIT",
      palette = { { 16, 26, 24 }, { 30, 64, 58 }, { 92, 200, 150 }, { 206, 255, 226 } } },
    { id = "TRAIN",  pattern = "TRAIN",
      palette = { { 240, 236, 226 }, { 196, 188, 172 }, { 128, 122, 112 }, { 52, 50, 48 } } },
    -- FAVOURITE is a category with no look of its own: it wears whatever was
    -- last marked with SELECT in the chooser, so changing your favourite
    -- changes every box that trusts it -- one press, and the whole PC
    -- redecorates.
    --
    -- It is LAST, and stays last however many places get added in front of
    -- it. Up and down walk this list, and a category that is a pointer to
    -- another one belongs at the end of the walk rather than sitting in the
    -- middle of the real places, where it reads as a scene that failed to
    -- draw.
    { id = "FAVE", pattern = "PLAIN", palette = nil },
  }
  local WALLPAPER_BY_ID = {}
  for _, w in ipairs(WALLPAPERS) do WALLPAPER_BY_ID[w.id] = w end

  -- ------- who drew it
  --
  -- A wallpaper is now a PLACE and a HAND: FOREST says what you are looking
  -- at, the artist says how it looks. Every category starts with the one
  -- drawn here -- that is the default, and the only one that needs no files
  -- -- and then lists the pixel artists whose work ships with the mod.
  --
  -- The art is real pixel art, quantised to each category's own four
  -- colours at build time (tools/build_art.py), so what the file holds is
  -- already what the SGB pass would make of it: BIG's remap finds nothing
  -- left to change, and CLASSIC draws it as it is.
  --
  -- Licences travel with the names. CC0 asks for nothing; CC BY asks for
  -- credit, and the credit is in the menu itself -- the artist's name is
  -- what you scroll through to pick their work. THIRD_PARTY_NOTICES.md
  -- carries the full text for both.
  local ART = "mods/gen3_box/assets/wallpapers/"
  -- Pixels per tick for a painted layer's pan. Slow on purpose: a 160-pixel
  -- margin takes about a minute and a half to cross, which reads as a scene
  -- that is alive rather than as something sliding past.
  local STILL_DRIFT = 0.03
  -- Each style is a STACK, not a picture. The pack every one of these comes
  -- from ships its scene in layers, and those layers are the animation: the
  -- clouds loop, the buildings do not. Flattening them into one image threw
  -- that away, and scrolling the flattened result dragged a seam across the
  -- box -- which is why an earlier build had to freeze most of them.
  --
  -- Which layer moves is measured, not guessed: the mean difference between
  -- a layer's first and last columns says whether it continues into itself.
  -- Cyclic layers scroll, painted ones hold still, and the file names carry
  -- the verdict -- _far and _near loop, _base does not.
  -- Each style is a list of layers drawn back to front, with the speed each
  -- one is allowed to move at. Zero means still, and most of them are: only
  -- a layer whose right edge continues into its left can be scrolled without
  -- dragging the join across the box. Which is which is not a guess -- run
  -- `tools/check_wallpaper.py` and it measures every file and says so. The
  -- names carry the verdict: _far and _near loop, _base and _still do not.
  --
  -- Speed zero does NOT mean a dead picture. A painted layer is wider than
  -- the screen, and the pixels past the right edge are the artist's work
  -- nobody was ever going to see: the box pans slowly across that margin
  -- and turns back before it runs out, so the scene breathes, the whole
  -- painting comes round in time, and the join at the ends is never on
  -- screen to be seen. `still = true` opts a layer out of even that.
  -- A drawn ENTRY: the same scene through another palette, or another
  -- scene's pattern under this place's name. Both are hands in the menu,
  -- because that is what they are to whoever is scrolling: SAKURA by day
  -- and SAKURA at night are two wallpapers, not one wallpaper and a
  -- setting. The names say GEN3 so nobody reads them as somebody else's
  -- work -- these are drawn here, in this file, like the first one.
  local function V(name, palette, pattern)
    return { by = name, palette = palette, pattern = pattern }
  end

  local function L(image, speed, still)
    return { image = ART .. image, speed = speed or 0, still = still or nil }
  end

  local WALLPAPER_ART = {
    SEA    = { { by = "GEN3 BOX" },
               { by = "SCRIBE",    layers = { L("sea_scribe_near.png", 0.05) } },
               { by = "REACTOR",   layers = { L("sea_reactorcore_base.png", 0.06) } },
               V("GEN3 DEEP", { { 18, 40, 72 }, { 30, 74, 122 }, { 66, 140, 190 }, { 150, 220, 236 } }),
               V("GEN3 DAWN", { { 254, 238, 226 }, { 244, 186, 168 }, { 176, 132, 156 }, { 60, 52, 92 } }) },
    FOREST = { { by = "GEN3 BOX" },
               { by = "ANSIMUZ",   layers = { L("forest_ansimuz_still.png") } },
               -- rebuilt in 1.10.2: the pack is drawn at 1280x360, and
               -- cutting a 144-row window out of that is not a smaller
               -- picture, it is a fragment of a big one -- which is why
               -- this used to be a bare trunk and a green triangle on two
               -- flat rectangles. Scaled down by two and a half instead,
               -- so the whole scene is in the frame.
               { by = "MATIASVME", layers = { L("forest_matiasvme_base.png", 0.02),
                                              L("forest_matiasvme_near.png", 0.09) } },
               V("GEN3 AUTUMN", { { 252, 238, 214 }, { 232, 176, 100 }, { 186, 106, 56 }, { 74, 46, 34 } }),
               V("GEN3 NIGHT", { { 22, 32, 34 }, { 40, 62, 58 }, { 92, 130, 104 }, { 196, 226, 198 } }) },
    SKY    = { { by = "GEN3 BOX" },
               -- 160x144, not 320: this pack is drawn at 160x80, so at its
               -- own scale the whole valley fits one CLASSIC screen. The
               -- 320-wide build had 64 rows of nothing under it, which
               -- shipped as a slab of flat grey across the bottom half.
               { by = "DUSTDFG",   layers = { L("sky_dustdfg_base.png"),
                                              L("sky_dustdfg_far.png", 0.05),
                                              L("sky_dustdfg_near.png", 0.11) } },
               { by = "FABINHOSC", layers = { L("sky_fabinhosc_still.png") } },
               { by = "GRUMPY",    layers = { L("sky_grumpydiamond_base.png", 0.02),
                                              L("sky_grumpydiamond_far.png", 0.06) } },
               -- AURORA lives here rather than as a place of its own: a sky
               -- with the lights in it is still a sky, and one hand on a
               -- category is not a category
               V("GEN3 AURORA", { { 12, 18, 34 }, { 40, 72, 96 }, { 96, 214, 176 }, { 214, 246, 226 } }, "AURORA"),
               V("GEN3 DUSK", { { 254, 226, 196 }, { 244, 158, 128 }, { 156, 100, 140 }, { 44, 40, 78 } }) },
    CAVE   = { { by = "GEN3 BOX" },
               { by = "ADMURIN",   layers = { L("cave_admurin_near.png", 0.04) } },
               { by = "PWL",       layers = { L("cave_pwl_base.png", 0.02) } },
               { by = "JONATHAN",  layers = { L("cave_jonathan_base.png", 0.02) } },
               V("GEN3 ICE", { { 232, 244, 252 }, { 176, 208, 232 }, { 104, 146, 190 }, { 40, 56, 88 } }),
               V("GEN3 EMBER", { { 30, 22, 24 }, { 74, 44, 40 }, { 168, 92, 56 }, { 244, 196, 132 } }) },
    CITY   = { { by = "GEN3 BOX" },
               { by = "FABINHOSC", layers = { L("city_fabinhosc_still.png"),
                                              L("city_fabinhosc_base.png"),
                                              L("city_fabinhosc_near.png", 0.12) } },
               { by = "ANSIMUZ",   layers = { L("city_ansimuz_base.png", 0.02) } },
               { by = "ANSIMUZ 2", layers = { L("city_ansimuz2_base.png") } },
               V("GEN3 NEON", { { 16, 12, 32 }, { 62, 30, 88 }, { 214, 62, 150 }, { 92, 240, 236 } }),
               V("GEN3 DAWN", { { 252, 234, 222 }, { 232, 178, 168 }, { 152, 122, 148 }, { 52, 46, 70 } }) },
    SNOW   = { { by = "GEN3 BOX" },
               { by = "ADMURIN",   layers = { L("snow_admurin_base.png"),
                                              L("snow_admurin_still.png") } },
               { by = "EMCEE",     layers = { L("snow_emcee_base.png", 0.02) } },
               { by = "JETREL",    layers = { L("snow_jetrel_base.png", 0.02) } },
               { by = "TIOAIMAR",  layers = { L("snow_tioaimar_base.png", 0.02) } },
               { by = "RUBBERDUCK", layers = { L("snow_rubberduck_base.png", 0.02) } },
               V("GEN3 DUSK", { { 250, 226, 232 }, { 208, 178, 210 }, { 140, 128, 176 }, { 52, 50, 84 } }) },
    NIGHT  = { { by = "GEN3 BOX" },
               { by = "LEYREN",    layers = { L("night_leyren_base.png") } },
               { by = "LLGD",      layers = { L("night_llgd_base.png", 0.05) } },
               { by = "FRIDARUIZ", layers = { L("night_fridaruiz_base.png", 0.02) } },
               { by = "TIGITAL",   layers = { L("night_tigital_base.png", 0.03) } },
               V("GEN3 BLOOD", { { 26, 14, 20 }, { 72, 26, 36 }, { 160, 58, 62 }, { 244, 196, 168 } }),
               V("GEN3 MOSS", { { 14, 24, 22 }, { 34, 58, 50 }, { 84, 132, 104 }, { 206, 232, 200 } }) },
    ["90S"] = { { by = "GEN3 BOX" },
               V("GEN3 MINT", { { 236, 252, 246 }, { 92, 210, 186 }, { 244, 148, 96 }, { 42, 66, 88 } }),
               V("GEN3 SUNSET", { { 254, 240, 220 }, { 246, 132, 92 }, { 122, 106, 200 }, { 44, 38, 70 } }),
               V("GEN3 GRAPE", { { 244, 238, 252 }, { 176, 132, 220 }, { 96, 200, 176 }, { 52, 40, 84 } }),
               V("GEN3 MONO", { { 246, 246, 244 }, { 176, 176, 176 }, { 104, 104, 104 }, { 36, 36, 36 } }) },
    -- The five newest places have one hand each so far. CC0 parallax art
    -- for a cherry tree, an aurora, a circuit board or a train window is
    -- not a thing that exists in quantity -- which is exactly what the
    -- contest in CONTEST.md is for.
    SAKURA = { { by = "GEN3 BOX" },
               V("GEN3 NIGHT", { { 26, 22, 44 }, { 62, 48, 86 }, { 176, 108, 154 }, { 250, 216, 232 } }),
               V("GEN3 DUSK", { { 252, 226, 214 }, { 244, 168, 156 }, { 186, 106, 132 }, { 70, 44, 68 } }),
               V("GEN3 SNOW", { { 252, 252, 254 }, { 218, 232, 244 }, { 152, 176, 206 }, { 66, 78, 104 } }),
               V("GEN3 EMBER", { { 254, 240, 216 }, { 246, 186, 108 }, { 208, 106, 62 }, { 78, 46, 40 } }) },
    STORM  = { { by = "GEN3 BOX" },
               V("GEN3 NIGHT", { { 22, 26, 40 }, { 52, 60, 84 }, { 108, 122, 156 }, { 208, 220, 240 } }),
               V("GEN3 DUSK", { { 242, 226, 226 }, { 190, 168, 178 }, { 122, 106, 128 }, { 46, 40, 56 } }),
               V("GEN3 SEA", { { 224, 240, 240 }, { 148, 190, 194 }, { 76, 122, 136 }, { 26, 46, 60 } }),
               V("GEN3 MONO", { { 240, 240, 240 }, { 170, 170, 170 }, { 100, 100, 100 }, { 30, 30, 30 } }) },
    CIRCUIT = { { by = "GEN3 BOX" },
               V("GEN3 AMBER", { { 26, 20, 12 }, { 62, 46, 22 }, { 210, 152, 48 }, { 254, 232, 176 } }),
               V("GEN3 BLUE", { { 12, 18, 34 }, { 28, 48, 88 }, { 82, 148, 232 }, { 206, 232, 255 } }),
               V("GEN3 RED", { { 26, 12, 16 }, { 64, 22, 30 }, { 208, 60, 66 }, { 252, 200, 196 } }),
               V("GEN3 MONO", { { 16, 16, 16 }, { 48, 48, 48 }, { 140, 140, 140 }, { 236, 236, 236 } }) },
    TRAIN  = { { by = "GEN3 BOX" },
               V("GEN3 NIGHT", { { 20, 22, 32 }, { 46, 50, 68 }, { 104, 108, 132 }, { 226, 228, 240 } }),
               V("GEN3 DUSK", { { 252, 226, 194 }, { 226, 162, 122 }, { 142, 100, 96 }, { 46, 38, 44 } }),
               V("GEN3 SNOW", { { 250, 252, 254 }, { 206, 220, 232 }, { 136, 156, 176 }, { 52, 60, 72 } }),
               V("GEN3 SEPIA", { { 246, 234, 206 }, { 204, 178, 140 }, { 138, 112, 82 }, { 56, 44, 34 } }) },
    DESERT = { { by = "GEN3 BOX" },
               { by = "EMCEE",     layers = { L("desert_emcee_base.png", 0.02),
                                              L("desert_emcee_near.png", 0.07) } },
               { by = "CETHIEL",   layers = { L("desert_cethiel_base.png", 0.02) } },
               { by = "BEVOULIIN", layers = { L("desert_bevouliin_base.png", 0.03) } },
               V("GEN3 DUSK", { { 254, 224, 196 }, { 240, 158, 122 }, { 168, 96, 116 }, { 52, 40, 66 } }),
               V("GEN3 MOON", { { 24, 26, 44 }, { 56, 58, 88 }, { 132, 128, 152 }, { 236, 232, 220 } }) },
    VOLCANO = { { by = "GEN3 BOX" },
               { by = "TIOAIMAR",  layers = { L("volcano_tioaimar_base.png", 0.02),
                                              L("volcano_tioaimar_near.png", 0.06) } },
               V("GEN3 ASH", { { 26, 24, 26 }, { 62, 58, 62 }, { 138, 128, 126 }, { 232, 224, 214 } }),
               V("GEN3 NIGHT", { { 14, 14, 26 }, { 44, 34, 62 }, { 168, 68, 92 }, { 250, 190, 120 } }),
               V("GEN3 EMBER", { { 30, 18, 14 }, { 84, 34, 22 }, { 220, 104, 32 }, { 254, 226, 150 } }) },
    SPACE  = { { by = "GEN3 BOX" },
               { by = "CLICKETY",  layers = { L("space_theclicketyboom_base.png", 0.03) } },
               { by = "RAWDANITSU", layers = { L("space_rawdanitsu_base.png") } },
               { by = "BONSAI",    layers = { L("space_bonsai_base.png", 0.04) } },
               { by = "SCREAMING", layers = { L("space_screaming_base.png", 0.02) } },
               V("GEN3 RED", { { 22, 10, 18 }, { 72, 24, 48 }, { 190, 74, 96 }, { 252, 222, 214 } }) },
    CASTLE = { { by = "GEN3 BOX" },
               { by = "JETREL",    layers = { L("castle_jetrel_base.png") } },
               { by = "RUBBERDUCK", layers = { L("castle_rubberduck_base.png") } },
               { by = "ANSIMUZ",   layers = { L("castle_ansimuz_base.png") } },
               V("GEN3 DUSK", { { 250, 226, 214 }, { 202, 170, 172 }, { 128, 106, 118 }, { 44, 38, 48 } }),
               V("GEN3 NIGHT", { { 22, 24, 36 }, { 50, 54, 74 }, { 112, 118, 146 }, { 226, 230, 244 } }) },
    PLAIN  = { { by = "GEN3 BOX" } },
    FAVE   = { { by = "GEN3 BOX" } },
  }
  mod.exports.wallpaperArt = WALLPAPER_ART

  -- ------- FAVOURITES
  --
  -- A set, not a single mark: SELECT adds what you are looking at, SELECT
  -- again on the same pair takes it back out. FAVOURITE then means "one of
  -- mine" rather than "the one", which is the difference between a shortcut
  -- and a shelf.
  --
  -- A beta shipped this as one saved pair under `favePaper`. That save is
  -- read once and folded into the list, so nobody who tried it loses the
  -- wallpaper they marked.
  local function faveList()
    local list = mod.save:get("favePapers")
    if type(list) ~= "table" then
      list = {}
      local old = mod.save:get("favePaper")
      if type(old) == "table" and type(old.id) == "string" then
        list[1] = { id = old.id, art = tonumber(old.art) or 1 }
      end
      mod.save:set("favePapers", list)
    end
    return list
  end

  local function faveIndexOf(id, art)
    for i, f in ipairs(faveList()) do
      if f.id == id and (tonumber(f.art) or 1) == art then return i end
    end
    return nil
  end

  -- returns the new state: true if it is now a favourite, false if removed
  local function toggleFave(id, art)
    local list = faveList()
    local at = faveIndexOf(id, art)
    if at then
      table.remove(list, at)
      mod.save:set("favePapers", list)
      return false
    end
    list[#list + 1] = { id = id, art = art }
    mod.save:set("favePapers", list)
    return true
  end

  -- Which favourite a box wearing FAVOURITE is showing. Drawn per box and
  -- held for the life of the screen: a wallpaper that reshuffled every frame
  -- would be a strobe, and one that never changed would make the set
  -- pointless. Open the PC again and the draw is new.
  local faveRoll = {}
  local function favePick(n)
    local list = faveList()
    if #list == 0 then return nil end
    local key = tostring(n or 0)
    local at = faveRoll[key]
    if not at or at > #list then
      at = math.random(#list)
      faveRoll[key] = at
    end
    local f = list[at]
    return f.id, tonumber(f.art) or 1
  end

  -- every reader goes through this: FAVE is never a look, it is a pointer
  local function resolvePaper(id, art, n)
    if id == "FAVE" then
      local fid, fart = favePick(n)
      if fid then return fid, fart end
      return "PLAIN", 1
    end
    return id, art
  end

  local function artFor(paperId)
    return WALLPAPER_ART[paperId] or { { by = "GEN3 BOX" } }
  end
  mod.exports.wallpaperArt = WALLPAPER_ART
  -- The list itself, for a harness that renders every pattern to a file --
  -- see self.drawWallpaper. Read-only in practice: nothing here writes to it.
  mod.exports.wallpapers = WALLPAPERS

  -- boxPapers, the same string-key-tolerant shape as boxNames above.
  -- ------- what a box remembers
  --
  -- 1.9.x stored a bare id string per box. It now stores the artist too, and
  -- both shapes have to keep working: a save written before this release
  -- names a category and means "the one drawn here", which is index 1.
  local function paperEntry(n)
    local papers = mod.save:get("boxPapers")
    local e = papers and (papers[n] or papers[tostring(n)])
    if type(e) == "string" then return { id = e, art = 1 } end
    if type(e) == "table" and type(e.id) == "string" then
      return { id = e.id, art = tonumber(e.art) or 1 }
    end
    return { id = "PLAIN", art = 1 }
  end

  local function setPaperEntry(n, id, art)
    local papers = mod.save:get("boxPapers")
    if not papers then
      papers = {}
      mod.save:set("boxPapers", papers)
    end
    papers[n] = { id = id, art = art }
    papers[tostring(n)] = nil
  end

  local function paperIdOf(n)
    local e = paperEntry(n)
    local id = resolvePaper(e.id, e.art, n)
    return WALLPAPER_BY_ID[id] and id or "PLAIN"
  end

  local function paperOf(n)
    return WALLPAPER_BY_ID[paperIdOf(n)] or WALLPAPER_BY_ID.PLAIN
  end

  -- which hand drew the paper this box is wearing
  local function artOf(n)
    local e = paperEntry(n)
    local id, art = resolvePaper(e.id, e.art, n)
    local list = artFor(id)
    return list[math.max(1, math.min(#list, art))] or list[1]
  end

  -- ------- the pic for ONE Pokemon, not for its species (issue #2)
  --
  -- This used to read `def.spriteFront` straight off the species record and
  -- hand it to Assets.image. That is right about the species and wrong about
  -- the Pokemon: two of the same species -- one shiny, one not -- are one
  -- record and one path, so the grid drew them identically and the shiny
  -- flag went nowhere.
  --
  -- src/pokemon/Sprites.lua is the sanctioned seam for exactly this, and its
  -- own header says why: content registries freeze after load, so a mod that
  -- gives a PARTICULAR Pokemon its own art cannot patch pokemon.spriteFront
  -- and instead answers the `pokemon.sprite` hook, which stays live for the
  -- whole process. `opts.mon` is the field that hook reads to tell one
  -- Pokemon from another -- it is commented "the live mon when available
  -- (per-instance skins)" -- so passing the mon is the whole fix. Shiny art
  -- from another mod, an alternate skin, Gen 2's own shiny flag: all of them
  -- arrive through that one call.
  --
  -- `kind = "summary"` because that is what this screen is to a wrapper: a
  -- menu showing one Pokemon's own picture, not a battle.
  local function picOf(game, mon)
    local def = defOf(game, mon)
    if not def then return nil end

    -- Two candidates, tried in order, and the ORDER is the whole lesson of
    -- 1.8.1-beta.1: the per-instance answer first, the species record second.
    --
    -- The seam can hand back a path this screen cannot draw. A mod that
    -- renders a Pokemon some other way -- voxels, 3D, an atlas of its own --
    -- legitimately answers `pokemon.sprite` with something that is not a
    -- plain 2D image file, and Assets.image then loads nothing. The first
    -- cut of this fix treated that as "no picture" and drew an empty cell,
    -- which is worse than the bug it was fixing: a wrong picture at least
    -- tells you which Pokemon is in the slot.
    --
    -- So a candidate that does not produce an image is not an answer, and
    -- the species record is tried next. Assets.image can also return nil
    -- WITHOUT throwing, which is why the image itself is tested rather than
    -- just the pcall.
    local seen = {}
    local function tryPath(path)
      if type(path) ~= "string" or path == "" or seen[path] then return nil end
      seen[path] = true
      local ok, img = pcall(Assets.image, path)
      if ok and img then return img end
      return nil
    end

    -- 1. What this PARTICULAR Pokemon should look like. Sprites.path raises
    --    `pokemon.sprite` with the live mon in its ctx, which is how a shiny
    --    is told apart from an ordinary one of the same species (issue #2).
    --
    --    It answers `path, trueColor` (src/pokemon/Sprites.lua:24-42), and
    --    the SECOND value is the one issue #4 turned on: it is the sprite
    --    mod's own word for "this art is already coloured", either from the
    --    species record's `trueColor` or set on the ctx by its
    --    `pokemon.sprite` hook. Dropping it -- which is what this line did --
    --    left drawPic unable to tell Crystal art from a four-shade Gen 1
    --    pic, so both went under the shade remap and the coloured one came
    --    out wrong. It is returned alongside the image from here on.
    local okPath, resolved, trueColor = pcall(Sprites.path, game.data,
      mon.species, "front", { mon = mon, kind = "summary" })

    -- ------- UNOWN, whose picture is not the species' (issue #7)
    --
    -- The letter is a property of the MON: GetUnownLetter packs the middle
    -- two bits of its four DVs (src/core/gen2/Unown.lua). The species
    -- record's own `spriteFront` is letter A's pic, so a screen that
    -- resolves art from the species draws a boxful of identical As -- which
    -- is what a Ruins of Alph player saw here, twenty-six forms caught and
    -- one shown. Every engine screen that draws an Unown resolves the form
    -- first (BoxMenu:picFor, SummaryMenu, PokedexMenu) and this one did not.
    --
    -- It goes AFTER the hook and BEFORE the record: a pack that deliberately
    -- answered with its own art keeps it (its path differs from the record's),
    -- and a pass-through hook -- the ordinary case, and every unhooked boot --
    -- falls through to the form. `formSprite` answers nil rather than letter A
    -- when it cannot name the letter, so a mon with no DVs is left to the
    -- record instead of being coerced into an A.
    local formPath = nil
    do
      local okU, Unown = pcall(require, "src.core.gen2.Unown")
      if okU and type(Unown) == "table" and mon.species == Unown.SPECIES then
        local letter = Unown.monLetter(mon)
        if letter then
          formPath = Unown.formSprite(game.data and game.data.pokemon, letter)
          -- ...but only if it IS a form. `formSprite` never answers nil: with
          -- no `letters` table on the species it falls back to the species'
          -- own picture (src/core/gen2/Unown.lua:325), which is letter A's.
          -- Since 1.22.0 the form beats a sprite pack, so on a boot whose
          -- data carries no letters that fallback would win -- and put ONE
          -- picture, the A, on all twenty-six forms. Which is the bug that
          -- change was made to fix, wearing different clothes.
          --
          -- The tell is the `letters` table itself, asked directly.
          -- Comparing paths does not work: the species record IS letter A's
          -- picture, so a legitimate A would compare equal and be thrown
          -- away with the fallbacks. (The suite says so -- "col pack
          -- installato l'Unown A chiede ancora la figura della SUA lettera"
          -- fails the moment you try it that way.)
          local letters = def and def.letters
          local named = letters and Unown.name(Unown.index(letter))
          if not (named and letters[named]) then formPath = nil end
        end
      end
    end

    -- ------- THE LETTER BEATS THE PACK (issue #7, second report)
    --
    -- 1.21.3 let a sprite pack overrule the form: "a pack that deliberately
    -- answered with its own art keeps it". That was wrong, and it is why
    -- the letters were still all the same after that fix while the game's
    -- OWN box showed them correctly.
    --
    -- The engine's Gold box never asks the sprite seam at all. It reads the
    -- species record and then puts the form over it
    -- (src/ui/gen2/BoxMenu.lua:668-676), so a pack cannot reach an Unown
    -- there. This screen does ask, the pack answers with the ONE Unown
    -- picture it has -- `pokemon.sprite` is keyed by species -- and that
    -- single picture went on all twenty-six forms. From the outside it
    -- looks exactly like the mod rewriting your Unown, which is what it
    -- was reported as.
    --
    -- So for Unown the form wins, full stop, which is what every engine
    -- screen does. A pack that genuinely wants to draw the forms has the
    -- place the engine reads them from -- the species' own `letters` table,
    -- one entry per letter -- and that route is honoured here, because it
    -- is where formSprite looks. What a pack may no longer do is replace
    -- twenty-six pictures with one through a seam that only knows species.
    if okPath and not formPath then
      local img = tryPath(resolved)
      if img then return img, trueColor and true or false, resolved end
    end
    if formPath then
      local img = tryPath(formPath)
      if img then return img, def.trueColor and true or false, formPath end
      -- the form exists but its file does not: the hook's answer is still
      -- better than nothing
      local hooked = okPath and tryPath(resolved) or nil
      if hooked then return hooked, trueColor and true or false, resolved end
    end

    -- 2. The species record: an older engine with no seam, a wrapper that
    --    threw, or art this screen cannot draw. Going through Assets.image
    --    means a Crystal-sprites mod's replacement art still shows up here,
    --    rather than this screen pinning the vanilla PNG. A record that
    --    carries its own art carries its own `trueColor` with it.
    return tryPath(def.spriteFront), def.trueColor and true or false, def.spriteFront
  end

  -- ------- A POKEMON IN THE BOX BREATHES (GRID BIG)
  --
  -- The same seam the dex uses, and for the same reason. Sprite packs that
  -- animate -- crystal_animated_sprites_with_shiny_visuals is the one this
  -- was written against -- keep one folder per species and number the frames
  -- inside it, `.../front/normal/25/001.png`. `pokemon.sprite` hands back a
  -- single path and always answers frame one (src/pokemon/Sprites.lua
  -- returns a string, never a list), but that path is the map: the frames
  -- beside it are the same name with the next number, found by asking until
  -- the answer is no.
  --
  -- Nothing here knows the pack's name or its layout, so any pack that
  -- numbers its frames animates, and art with no siblings -- the ROM's own
  -- pictures -- has no second frame and stays exactly as still as before.
  -- The fallback is not a branch: "no sibling" and "no pack" are one answer.
  --
  -- The run must START at 1. A ROM sprite whose name ends in digits would
  -- otherwise walk from `025.png` into `026.png`, which is the NEXT SPECIES'
  -- picture, and animate a Pikachu into a Raichu.
  --
  -- Cached by PATH rather than by species: two mons of one species share the
  -- frames, and a shiny -- whose hook answers a different path -- gets its
  -- own set without asking for them twice.
  -- ONE name reaches the screen, and that is not tidiness either: LuaJIT
  -- allows a function 60 upvalues and the screen closure is already near
  -- the line. A first cut exported the cache and two constants as well and
  -- pushed it over -- "function at line 2643 has more than 60 upvalues",
  -- which is not a warning, it is the mod failing to load at all. So the
  -- constants and the cache live in here, the frame arithmetic comes with
  -- them, and the caller asks one question: which picture, right now.
  local animFrameFor
  do
    local ANIM_MAX = 64    -- a bad match stops here rather than never
    local ANIM_EVERY = 6   -- logic steps per sprite frame, about 10fps
    local cache = {}
    function animFrameFor(path, firstImg, tick)
      if type(path) ~= "string" or not firstImg then return firstImg end
      local frames = cache[path]
      if frames == nil then
        local dir, num, ext = path:match("^(.*[/\\])(%d+)(%.[%a%d]+)$")
        if not dir or tonumber(num) ~= 1 then
          cache[path] = false
          return firstImg
        end
        local pattern = "%s%0" .. #num .. "d%s"
        frames = { firstImg }
        for i = 2, ANIM_MAX do
          local ok, img = pcall(Assets.image, pattern:format(dir, i, ext))
          if not (ok and img) then break end
          frames[#frames + 1] = img
        end
        if #frames < 2 then frames = false end
        cache[path] = frames
      end
      if not frames then return firstImg end
      return frames[1 + math.floor((tick or 0) / ANIM_EVERY) % #frames]
    end
  end

  -- ------- marks (Gen 3's CIRCLE/SQUARE/TRIANGLE/HEART)
  --
  -- One accessor pair, mon.gen3Marks a four-character "0"/"1" string
  -- (PLAN.md "MARKS"): FIND's MARK search and the marking window both go
  -- through getMark/setMark rather than each rolling its own string
  -- indexing. A plain string rather than a table of booleans: it survives
  -- SaveSerializer.encode/decode as one value (any data-only field on a mon
  -- does, docs/modding.md:271) and cannot half-exist the way a sparse array
  -- can.
  local MARK_ORDER = { "CIRCLE", "SQUARE", "TRIANGLE", "HEART" }
  local MARK_LETTER = { CIRCLE = 1, SQUARE = 2, TRIANGLE = 3, HEART = 4 }

  local function getMark(mon, name)
    local s = mon.gen3Marks
    if type(s) ~= "string" then return false end
    local i = MARK_LETTER[name]
    return s:sub(i, i) == "1"
  end

  local function setMark(mon, name, on)
    local s = mon.gen3Marks
    if type(s) ~= "string" or #s ~= 4 then s = "0000" end
    local i = MARK_LETTER[name]
    mon.gen3Marks = s:sub(1, i - 1) .. (on and "1" or "0") .. s:sub(i + 1)
  end

  local function anyMarks(mon)
    local s = mon.gen3Marks
    return type(s) == "string" and s:find("1", 1, true) ~= nil
  end

  -- ------- MAIL (Gen 2 only)
  --
  -- Gold keeps every letter in save.mail.party, sparse and keyed by PARTY
  -- SLOT rather than by mon (src/core/gen2/Mail.lua). This screen moves
  -- mons through save.party with its own table.remove/table.insert rather
  -- than going through Boxes.deposit/withdraw, so the letters do not follow
  -- along for free the way they do on the cart -- these three are what keep
  -- them attached, called at the actual party-mutation sites below rather
  -- than from one wrapper that only covers one of them. Reached through a
  -- pcall'd require so a Gen 1 boot, where this module does not exist,
  -- never sees it.
  local function gen2Mail()
    local ok, Mail = pcall(require, "src.core.gen2.Mail")
    return ok and type(Mail) == "table" and Mail or nil
  end

  local function monHoldsMail(mon)
    local Mail = gen2Mail()
    return Mail ~= nil and Mail.monHoldsMail(mon) == true
  end

  -- Mail.lua has a removeSlot (a departure shifts every letter behind it
  -- down) but no mirror for an ARRIVAL: RemoveMonFromPartyOrBox only ever
  -- shifts down, because the cart never inserts a mon into the middle of
  -- the party -- WITHDRAW always appends at the tail
  -- (src/core/gen2/Boxes.lua:128-135's own #party+1). This screen's own
  -- moves keep that same "always append at the tail" shape today, but every
  -- site that grows save.party calls this anyway: it shifts whatever sits
  -- from `slot` to the end UP one and clears `slot`, so a mon landing there
  -- -- which the refusals elsewhere guarantee never carries mail of its own
  -- -- never inherits a letter that belonged to whoever the array shift
  -- moved past it.
  local function gen2InsertPartySlot(game, slot)
    local Mail = gen2Mail()
    if not Mail then return end
    local party = Mail.state(game.save).party
    for i = Mail.PARTY_LENGTH, slot + 1, -1 do
      party[i] = party[i - 1]
    end
    party[slot] = nil
  end

  -- ------- the Gen 2 stat block
  --
  -- Gen 2's box_struct is the same byte-for-byte-prefix story Stats.ensure's
  -- own comment tells for Gen 1: a mon decoded without a party's worth of
  -- stat words arrives with mon.stats nil. src/battle/gen2/Mon.lua:67 is the
  -- Gen 2 formula (Special split into specialAttack/specialDefense, one DV
  -- feeding both); this only ever fills a MISSING block, the same contract
  -- Stats.ensure keeps for Gen 1.
  local function gen2EnsureStats(game, mon)
    if type(mon) ~= "table" or mon.stats ~= nil then return end
    local def = defOf(game, mon)
    if type(def) ~= "table" or type(def.baseStats) ~= "table" then return end
    local ok, Gen2Mon = pcall(require, "src.battle.gen2.Mon")
    if not ok or not Gen2Mon then return end
    local okStats, stats = pcall(Gen2Mon.stats, def.baseStats, mon.dvs,
      mon.level or 1, mon.statExp)
    if not okStats or type(stats) ~= "table" then return end
    mon.stats = stats
    mon.hp = math.max(0, math.min(tonumber(mon.hp) or stats.hp, stats.hp))
  end

  -- ------- the box as a nurse, Gen 2's own
  --
  -- Pokemon.heal reads mon.stats.hp and restores PP out of src.core.Data,
  -- the Gen 1 singleton -- not the dataset a Gold boot actually runs, and a
  -- box mon may carry no .stats at all, which is what made the pcall around
  -- it a silent no-op on Gold. HealParty's own recipe (engine/events/
  -- heal_party.asm), read off game.data.moves instead of that singleton.
  local function gen2Heal(game, mon)
    gen2EnsureStats(game, mon)
    if type(mon.stats) ~= "table" then return end
    mon.hp = mon.stats.hp
    mon.status = nil
    local moves = game.data and game.data.moves
    if type(moves) ~= "table" or type(mon.moves) ~= "table" then return end
    for _, mv in ipairs(mon.moves) do
      local mdef = moves[mv.id]
      if mdef then
        mv.pp = mdef.pp + (mv.ppUps or 0) * math.floor(mdef.pp / 5)
      end
    end
  end

  -- ------- the screen

  -- ------- the wallpaper painter, at mod scope
  --
  -- All of this lived inside the box screen's constructor, which was fine
  -- while the box was the only thing that wanted a scene behind it. The
  -- Pokedex wants the same ninety-one wallpapers, and the answer to that is
  -- not a second copy of the drawing code and a second copy of the art: it
  -- is one painter, exported, that any screen can call.
  --
  -- Taking the tick as an argument instead of reading it off a screen is
  -- the only change the move required.

  local function shade(paper, n, alpha)
    local c = paper.palette and paper.palette[n]
    if not c then return end
    love.graphics.setColor(c[1] / 255, c[2] / 255, c[3] / 255, alpha or 1)
  end

  -- A round shape the way a Game Boy makes one: rows of rectangles whose
  -- widths follow the circle, so the edge steps instead of feathering.
  -- love.graphics.circle at these radii comes out either as a dot or, when
  -- something lighter is drawn inside it, as a doughnut.
  -- love.graphics.polygon is not on every surface this file is drawn
  -- through -- the headless harness stubs a subset -- and a wallpaper is
  -- not worth a crash: no polygon, no shape, everything else still draws.
  local function poly(...)
    local f = love.graphics.polygon
    if f then f(...) end
  end

  -- A silhouette drawn COLUMN by column from a smooth profile, rather than
  -- as a row of triangles. Triangles are what a horizon looks like when
  -- nobody has looked at it: the dunes came out a zigzag and the volcano
  -- came out a fence. Two sines of different periods, plus a hashed
  -- wobble, give a ridge that repeats without reading as a pattern.
  local function ridge(w, h, baseY, amp, seed, step)
    step = step or 2
    for x = 0, w, step do
      local hx = ((x + seed) * 2654435761) % 4294967296
      local jitter = (math.floor(hx / 65536) % 5) - 2
      local y = baseY
        - math.floor(amp * math.sin((x + seed * 7) / 37))
        - math.floor(amp * 0.45 * math.sin((x + seed * 13) / 11))
        + jitter
      if y < h then
        love.graphics.rectangle("fill", x, y, step, h - y)
      end
    end
  end

  local function disc(cx, cy, r)
    for dy = -r, r do
      local half = math.floor(math.sqrt(math.max(0, r * r - dy * dy)))
      if half > 0 then
        love.graphics.rectangle("fill", cx - half, cy + dy, half * 2, 1)
      end
    end
  end

  -- ------- a wallpaper someone else drew
  --
  -- An art style is one wide strip -- two screens across -- scrolled at
  -- its own speed and drawn twice so the seam is always off-screen. That
  -- is the whole animation: no parallax layers, because a second layer
  -- doubles the files shipped for a motion nobody looks straight at while
  -- moving Pokemon around.
  --
  -- The strip is 144 tall, which is CLASSIC's own height, so BIG scales it
  -- by exactly two: an integer, so the pixels stay square and hard-edged
  -- instead of being resampled into mush.
  local artImages = {}
  local function artImage(style)
    if not (style and style.image) then return nil end
    local hit = artImages[style.image]
    if hit ~= nil then return hit or nil end
    local ok, img = pcall(Assets.image, style.image)
    artImages[style.image] = (ok and img) or false
    return (ok and img) or nil
  end

  local function drawArt(style, w, h, t)
    local layers = style and style.layers
    if not layers and style and style.image then
      layers = { { image = style.image, speed = style.speed or 0 } }
    end
    if not layers then return false end
    local drew = false
    for _, layer in ipairs(layers) do
      local img = artImage(layer)
      if img then
        local okDim, iw, ih = pcall(function()
          return img:getWidth(), img:getHeight()
        end)
        if okDim and iw and iw > 0 and ih and ih > 0 then
          -- ------- HOW BIG, and the answer is not "as big as the canvas"
          --
          -- Twice this got it wrong in opposite directions. `floor(h / ih)`
          -- left a 144-tall strip across the top of a 244-tall panel with a
          -- hundred rows of white under it. `ceil(h / ih)` covered the panel
          -- and then met the Pokedex, whose full-screen canvas is 576 tall:
          -- four times for a strip, NINE for one of Kenney's 64-pixel brick
          -- tiles. "sto sfondi fanno cacare, si vedono malissimo".
          --
          -- So: the smallest whole scale that covers, CAPPED AT TWO. Two is
          -- the size BIG draws at and the biggest an artist's pixel is meant
          -- to get; past it the art stops being art and becomes furniture.
          -- What the cap leaves uncovered is repeated rather than magnified
          -- -- these strips loop, repeating is what they are for, and a
          -- second copy of a scene reads as a pattern where a nine-times
          -- brick reads as a bug.
          local scale = math.max(1, math.min(2,
            math.max(math.ceil(h / ih), math.floor(w / 160))))
          local span = iw * scale
          local rows = ih * scale

          -- ------- WHERE, across
          --
          -- speed 0 is a layer that must not move: the buildings, the rock,
          -- the ground. Only what loops is allowed to slide. A still strip
          -- is centred and panned gently over whatever width it has spare,
          -- so the artist's composition is not cropped to its left half --
          -- which is what shipped for four releases.
          local ox = 0
          local range = span - w
          if (layer.speed or 0) > 0 then
            ox = math.floor(t * layer.speed) % span
          elseif range > 0 and not layer.still then
            local sweep = t * STILL_DRIFT + range / 2
            local u = sweep % (2 * range)
            ox = math.floor(u <= range and u or (2 * range - u))
          elseif range > 0 then
            ox = math.floor(range / 2)
          end

          -- ------- and down: crop from the middle, or repeat
          local oy = rows >= h and math.floor((rows - h) / 2) or 0
          local ok = pcall(function()
            love.graphics.setColor(1, 1, 1, 1)
            local y = -oy
            repeat
              local x = -ox
              while x < w do
                love.graphics.draw(img, x, y, 0, scale, scale)
                x = x + span
              end
              y = y + rows
            until y >= h
          end)
          drew = drew or ok
        end
      end
    end
    love.graphics.setColor(0, 0, 0, 1)
    return drew
  end

  -- Every scene below is drawn in literal pixels of the 160x144 Game Boy
  -- screen: `for i = 0, 9` roofs at 18 apart is a street across THAT
  -- screen and nothing wider. So this takes the size it is given and
  -- paints at that size -- and the caller is what makes BIG work.
  local function drawPattern(paper, w, h, t)
    local pattern = paper.pattern
    -- The ground colour first: the whole surface, so nothing shows white
    -- except what this screen deliberately paints white on top.
    shade(paper, 1)
    love.graphics.rectangle("fill", 0, 0, w, h)

    if pattern == "SEA" then
      -- UNDER the water, not the surface of it. 1.9.3 drew bands of waves
      -- and 1.10.0's first attempt made those bands chunky, which fixed
      -- the hairlines and left the screen reading as knitting. What a box
      -- called SEA wants is the thing you look INTO: light on the surface
      -- overhead, weed on the floor, and something swimming between them.
      --
      -- Nothing here is copied from anywhere. A fish at this size is a
      -- body and a tail, and that shape belongs to nobody.

      -- the surface, rolling, along the top only
      for i = 0, 2 do
        local y = i * 6
        for x = -8, w + 8, 8 do
          local phase = math.sin((x + t * 0.6 + i * 13) / 15)
          local wy = y + math.floor(phase * 2) * 2
          shade(paper, 2, 0.5 - i * 0.12)
          love.graphics.rectangle("fill", x, wy, 8, 3)
        end
      end
      -- shafts of light coming down through it
      shade(paper, 1, 0.5)
      for i = 0, 3 do
        local x = (i * 47 + math.floor(t * 0.12)) % (w + 40) - 20
        poly("fill", x, 8, x + 10, 8, x + 22, h, x + 6, h)
      end

      -- the floor: weed that sways, and anemones sitting in it
      for i = 0, math.ceil(w / 11) do
        local x = i * 11 + 3
        local tall = 16 + ((i * 13) % 20)
        shade(paper, 3, 0.75)
        for seg = 0, tall, 4 do
          local bend = math.floor(2 * math.sin((t + i * 30 + seg * 9) / 38))
          love.graphics.rectangle("fill", x + bend, h - seg - 4, 3, 4)
        end
      end
      for i = 0, 3 do
        local x = 14 + i * 41
        local pulse = math.floor(1.5 + 1.5 * math.sin((t + i * 50) / 30))
        shade(paper, 4, 0.55)
        for arm = -4, 4 do
          love.graphics.rectangle("fill", x + arm * 3, h - 12 - pulse - math.abs(arm),
            2, 8 + pulse - math.abs(arm))
        end
        shade(paper, 4, 0.75)
        disc(x, h - 7, 6)
      end

      -- a fish: body, tail, eye. Two shoals crossing at different depths,
      -- so something is always moving under something else.
      local function fish(fx, fy, dir, tone, alpha, size)
        shade(paper, tone, alpha)
        disc(fx, fy, 2 * size)
        love.graphics.rectangle("fill", fx - 3 * size, fy - size, 6 * size, 2 * size)
        -- tail, behind the direction of travel
        poly("fill",
          fx - dir * 3 * size, fy,
          fx - dir * 6 * size, fy - 2 * size,
          fx - dir * 6 * size, fy + 2 * size)
        shade(paper, 1, 0.9)
        love.graphics.rectangle("fill", fx + dir * size, fy - size, size, size)
      end
      for i = 0, 4 do
        local y = 34 + i * 17
        local x = ((t * 0.5 + i * 43) % (w + 40)) - 20
        fish(x, y, 1, 3, 0.65, 1)
      end
      for i = 0, 2 do
        local y = 46 + i * 26
        local x = w - (((t * 0.75 + i * 61) % (w + 50)) - 25)
        fish(x, y, -1, 2, 0.9, 2)
      end

      -- a jellyfish drifting up through the lot
      for i = 0, 1 do
        local x = 30 + i * 74
        local y = h - ((t * 0.3 + i * 90) % (h + 40))
        shade(paper, 2, 0.55)
        disc(x, y, 6)
        love.graphics.rectangle("fill", x - 6, y, 12, 3)
        for k = -2, 2 do
          local wob = math.floor(2 * math.sin((t + k * 20 + i * 40) / 25))
          love.graphics.rectangle("fill", x + k * 3 + wob, y + 3, 1, 8)
        end
      end

      -- bubbles, still rising
      shade(paper, 1, 0.8)
      for i = 0, 11 do
        local bx = (i * 37) % w
        local by = h - ((t * 0.35 + i * 23) % (h + 12))
        love.graphics.rectangle("fill", bx, by, 2, 2)
      end
    elseif pattern == "FOREST" then
      -- TREES, drawn the way a Game Boy draws a tree: a stack of
      -- rectangles on the 8-pixel grid, widest at the bottom, with a trunk
      -- under it. 1.9.3 drew filled CIRCLES here, and a filled circle at
      -- this size on a four-tone surface is a dot -- the screen came out a
      -- field of green polka dots rather than a wood.
      --
      -- Two depths: a darker row behind, offset half a tree along and
      -- sitting higher, so the canopy reads as having something behind it
      -- rather than as one row of shapes. The sway moves whole PIXELS, not
      -- fractions -- a sub-pixel sway on a lattice this coarse just makes
      -- the edges shimmer.
      local function tree(cx, cy, scale, tone, alpha)
        shade(paper, tone, alpha)
        -- canopy: three tiers, each wider and shorter than the one above
        love.graphics.rectangle("fill", cx - 3 * scale, cy, 6 * scale, 3 * scale)
        love.graphics.rectangle("fill", cx - 5 * scale, cy + 3 * scale,
          10 * scale, 3 * scale)
        love.graphics.rectangle("fill", cx - 7 * scale, cy + 6 * scale,
          14 * scale, 3 * scale)
        -- trunk
        love.graphics.rectangle("fill", cx - scale, cy + 9 * scale,
          2 * scale, 3 * scale)
      end

      local STEP_X, STEP_Y = 24, 26
      for row = -1, math.ceil(h / STEP_Y) + 1 do
        -- the row behind, higher and darker
        for col = -1, math.ceil(w / STEP_X) + 1 do
          local sway = math.floor(2 * math.sin((t + row * 37 + col * 19) / 45))
          tree(col * STEP_X + 12 + sway, row * STEP_Y - 6, 1, 3, 0.5)
        end
        -- and the row in front, offset half a tree along
        for col = -1, math.ceil(w / STEP_X) + 1 do
          local sway = math.floor(2 * math.sin((t + row * 23 + col * 31) / 40))
          -- every third tree is a sapling: a lattice of identical trees is
          -- a wallpaper pattern, and a wood is not
          local small = ((row * 7 + col * 3) % 3 == 0)
          local x = col * STEP_X + sway
          if small then
            shade(paper, 2, 0.85)
            love.graphics.rectangle("fill", x - 3, row * STEP_Y + 12, 6, 3)
            love.graphics.rectangle("fill", x - 5, row * STEP_Y + 15, 10, 3)
            love.graphics.rectangle("fill", x - 1, row * STEP_Y + 18, 2, 3)
          else
            tree(x, row * STEP_Y + 6, 1, 2, 0.85)
          end
        end
      end
    elseif pattern == "SKY" then
      -- Clouds drifting right, two layers at different speeds so the sky
      -- has depth rather than a single sliding sheet.
      -- A cloud built from RECTANGLES: three overlapping circles came out
      -- as one soft lump, and three of them left most of the sky empty.
      -- This is the shape a Game Boy draws -- a wide flat base with two
      -- steps stacked on it -- and there are enough of them to be weather
      -- rather than decoration.
      local function cloud(cx, cy, u, tone, alpha)
        shade(paper, tone, alpha)
        love.graphics.rectangle("fill", cx, cy + 2 * u, 10 * u, 2 * u)
        love.graphics.rectangle("fill", cx + u, cy + u, 7 * u, u)
        love.graphics.rectangle("fill", cx + 3 * u, cy, 4 * u, u)
        -- the lit top edge, one row, which is what sells it as volume
        shade(paper, 1, 0.8)
        love.graphics.rectangle("fill", cx + 3 * u, cy, 4 * u, 1)
      end
      -- a sun, high and to one side, because an empty sky is not weather.
      -- Solid, with a ring of its own colour around it rather than a paler
      -- middle -- a lighter core turned it into a doughnut.
      shade(paper, 3, 0.35)
      disc(w - 30, 20, 13)
      shade(paper, 2, 0.9)
      disc(w - 30, 20, 10)

      -- the far layer: smaller, paler, slower
      for i = 0, 10 do
        local y = 4 + i * 14
        local x = ((t * 0.18 + i * 43) % (w + 80)) - 40
        cloud(x, y, 2, 3, 0.45)
      end
      -- and the near one, big enough to pass in front of the sun
      for i = 0, 7 do
        local y = 10 + i * 19
        local x = ((t * 0.34 + i * 57) % (w + 110)) - 55
        cloud(x, y, 3, 2, 0.8)
      end
    elseif pattern == "CAVE" then
      -- Third attempt, and the first two failed for the same reason in
      -- opposite directions: one was a flat beige wall with teeth on it,
      -- the other was a full scene -- arch, pool, dither, the lot -- which
      -- on a 160x144 field behind twenty Pokemon is just noise the sprites
      -- have to fight.
      --
      -- A wallpaper is not a painting. What it needs is a surface with a
      -- top, a bottom and enough going on between them to be a place:
      -- rock above, rock below, a seam of crystal that breathes, and the
      -- steady drip that says the room is alive. Middle contrast
      -- throughout, so a Pokemon standing on it still reads.

      -- the rock face, a shade under the ground colour
      shade(paper, 2, 0.4)
      love.graphics.rectangle("fill", 0, 0, w, h)

      -- texture: short horizontal strata, scattered rather than tiled, so
      -- the wall has grain without turning into a chessboard
      shade(paper, 3, 0.18)
      for i = 0, 45 do
        local hx = (i * 2654435761) % 4294967296
        local x = math.floor(hx / 65536) % w
        local y = math.floor(hx / 23) % h
        love.graphics.rectangle("fill", x, y, 5 + (i % 4) * 3, 2)
      end

      -- the ceiling: one unbroken dark band, its underside ragged
      shade(paper, 4, 0.75)
      for x = 0, w, 4 do
        local d = 10 + math.floor(6 * math.sin(x / 17) + 4 * math.sin(x / 7))
        love.graphics.rectangle("fill", x, 0, 4, d)
      end
      -- stalactites hanging from it
      for i = 0, 8 do
        local x = 4 + i * 19
        local len = 10 + ((i * 13) % 22)
        for k = 0, len do
          local half = math.max(1, math.floor(4 * (1 - k / len)))
          love.graphics.rectangle("fill", x - half, 12 + k, half * 2, 1)
        end
      end

      -- and the floor, the same band the other way up
      for x = 0, w, 4 do
        local u = 8 + math.floor(5 * math.cos(x / 15) + 3 * math.sin(x / 9))
        love.graphics.rectangle("fill", x, h - u, 4, u)
      end
      for i = 0, 6 do
        local x = 12 + i * 25
        local len = 8 + ((i * 17) % 16)
        for k = 0, len do
          local half = math.max(1, math.floor(4 * (1 - k / len)))
          love.graphics.rectangle("fill", x - half, h - 8 - k, half * 2, 1)
        end
      end

      -- mid-depth pillars: floor to ceiling, a shade lighter than the
      -- near rock, which is what stops the middle of the screen being a
      -- beige field with things at the edges of it
      shade(paper, 3, 0.26)
      for i = 0, 1 do
        local x = 26 + i * 82
        local width = 9 + (i % 2) * 4
        for y = 14, h - 12 do
          local waist = math.floor(3 * math.sin((y + i * 40) / 26))
          love.graphics.rectangle("fill", x + waist, y, width, 1)
        end
      end

      -- crystals GROWING OUT OF THE FLOOR, in clusters, glowing in and
      -- out. Floating them in mid-air made them read as little mountains
      -- hanging in the dark.
      local pulse = 0.35 + 0.3 * math.sin(t / 34)
      for i = 0, 4 do
        local x = 10 + i * 33
        local base = h - 10 - ((i * 7) % 5)
        for k = -1, 1 do
          local tall = 9 + ((i * 13 + k * 5) % 9) - math.abs(k) * 3
          local cx = x + k * 5
          shade(paper, 1, pulse + 0.2 - math.abs(k) * 0.08)
          poly("fill", cx - 2, base, cx, base - tall, cx + 2, base)
        end
        -- the light they throw on the floor around them
        shade(paper, 1, pulse * 0.35)
        love.graphics.rectangle("fill", x - 9, base, 20, 2)
      end

      -- drips, from a stalactite to the floor, one ring where they land
      for i = 0, 3 do
        local x = 4 + i * 19 * 2
        local period = h - 20
        local fall = (t * 1.2 + i * 41) % period
        shade(paper, 1, 0.7)
        love.graphics.rectangle("fill", x, 20 + fall, 1, 4)
        if fall > period - 8 then
          local age = fall - (period - 8)
          shade(paper, 1, 0.55 - age * 0.06)
          love.graphics.rectangle("fill", x - 2 - age, h - 14, 5 + age * 2, 1)
        end
      end
    elseif pattern == "CITY" then
      -- A skyline with lit windows, and the lights come on and go off.
      -- The skyline worked; the sky above it did not exist. A moon, a few
      -- stars and a second row of towers behind the first give the top
      -- two thirds of the screen something to be.
      local base = h
      -- a crescent: a disc with a bite taken out of it by the ground colour
      -- a crescent: the disc, then the SAME disc again in the sky's own
      -- colour, offset -- which is how the shape is cut on hardware
      shade(paper, 4, 0.7)
      disc(w - 30, 18, 11)
      shade(paper, 1, 1)
      disc(w - 25, 15, 11)
      shade(paper, 4, 0.6)
      for i = 0, 23 do
        local hx = (i * 2654435761) % 4294967296
        local x = math.floor(hx / 65536) % w
        local y = 3 + math.floor(hx / 11) % 52
        love.graphics.rectangle("fill", x, y, 1, 1)
      end
      -- the far towers: taller, darker, no windows, so the near row reads
      -- as being in front of something rather than against blank sky
      shade(paper, 3, 0.6)
      for i = 0, math.ceil(w / 22) do
        local x = i * 22 + 8
        local bh = 48 + ((i * 17) % 34)
        love.graphics.rectangle("fill", x, base - bh, 18, bh)
      end
      shade(paper, 2, 0.65)
      for i = 0, math.ceil(w / 16) do
        local x = i * 16
        local bh = 26 + ((i * 13) % 34)
        love.graphics.rectangle("fill", x, base - bh, 14, bh)
      end
      for i = 0, math.ceil(w / 16) do
        local x = i * 16
        local bh = 26 + ((i * 13) % 34)
        for wy = base - bh + 5, base - 6, 8 do
          for wx = x + 3, x + 10, 5 do
            local lit = math.sin((t + wx * 13 + wy * 7) / 55) > 0.2
            shade(paper, lit and 1 or 4, lit and 0.85 or 0.5)
            love.graphics.rectangle("fill", wx, wy, 3, 4)
          end
        end
      end
    elseif pattern == "SNOW" then
      -- Rooftops under falling snow, which is what a snow scene actually
      -- looks like: a town seen from above the eaves, chimneys smoking,
      -- and the fall thick enough to be weather. The palette is four
      -- colours, but in CLASSIC nothing remaps the canvas -- so the tones
      -- in between are the mod's own blending, and the scene can carry
      -- more depth than a four-shade sprite would.
      --
      -- Three ranks of roofs, each darker and lower than the one behind,
      -- so the town has distance in it.
      local horizon = math.floor(h * 0.52)

      -- HOUSES, not a fence of identical triangles. Each one gets its own
      -- width, its own height and its own roof pitch out of the same
      -- hash, so the row reads as a street rather than as a pattern; the
      -- two roof slopes take different tones, because a lit side and a
      -- shaded side is what makes a roof look like a roof; and the snow
      -- sits on the ridge as a thin cap with a lip, not as a white
      -- triangle laid over the whole thing.
      local function house(x, y, bw, bh, tone, alpha, snowAlpha)
        local half = math.floor(bw / 2)
        local peak = y - math.floor(bw * 0.42)
        -- wall
        shade(paper, tone, alpha)
        love.graphics.rectangle("fill", x, y, bw, bh)
        -- the two slopes: the left one catches the light
        shade(paper, tone, alpha * 0.8)
        poly("fill", x, y, x + half, peak, x + half, y)
        shade(paper, 4, math.min(1, alpha * 1.15))
        poly("fill", x + half, peak, x + bw, y, x + half, y)
        -- snow along both slopes, a couple of pixels thick, with the lip
        shade(paper, 1, snowAlpha)
        poly("fill", x - 1, y, x + half, peak - 2,
          x + half, peak + 1, x + 3, y + 1)
        poly("fill", x + bw + 1, y, x + half, peak - 2,
          x + half, peak + 1, x + bw - 3, y + 1)
        return peak
      end

      -- the far rank: small, pale, no detail
      for i = 0, 9 do
        local hx = (i * 2654435761) % 4294967296
        local bw = 14 + math.floor(hx / 65536) % 10
        local x = i * 18 - 6
        house(x, horizon, bw, h - horizon, 3, 0.4, 0.55)
      end

      -- the middle rank, with windows
      for i = 0, 6 do
        local hx = (i * 2246822519) % 4294967296
        local bw = 20 + math.floor(hx / 65536) % 12
        local x = i * 26 - 10
        local peak = house(x, horizon + 14, bw, h - horizon - 14, 3, 0.7, 0.8)
        local lit = math.sin((t + i * 61) / 80) > -0.2
        shade(paper, lit and 1 or 4, lit and 0.9 or 0.5)
        love.graphics.rectangle("fill", x + math.floor(bw / 2) - 2,
          horizon + 20, 4, 4)
        -- a chimney on some of them, smoking
        if i % 2 == 0 then
          shade(paper, 4, 0.85)
          love.graphics.rectangle("fill", x + bw - 7, peak + 2, 4, 10)
          for k = 0, 4 do
            local rise = (t * 0.45 + k * 11 + i * 17) % 40
            local drift = math.floor(math.sin((t + k * 26 + i * 20) / 24) * (1 + k))
            shade(paper, 2, 0.45 - k * 0.08)
            love.graphics.rectangle("fill", x + bw - 7 + drift, peak + 2 - rise,
              2 + math.floor(k / 2), 2 + math.floor(k / 2))
          end
        end
      end

      -- the near rank: big, dark, two rows of windows
      for i = 0, 4 do
        local hx = (i * 3266489917) % 4294967296
        local bw = 28 + math.floor(hx / 65536) % 14
        local x = i * 36 - 12
        house(x, horizon + 34, bw, h - horizon - 34, 4, 0.8, 0.95)
        for row = 0, 1 do
          for col = 0, 1 do
            local lit = math.sin((t + i * 43 + row * 31 + col * 17) / 70) > -0.1
            shade(paper, lit and 1 or 4, lit and 0.95 or 0.55)
            love.graphics.rectangle("fill", x + 6 + col * 12,
              horizon + 42 + row * 11, 5, 6)
          end
        end
      end

      -- and the fall itself: three depths, the near flakes bigger and
      -- quicker, so the snow has volume rather than being one sheet
      for depth = 1, 3 do
        local count = 16 + depth * 8
        local speed = 0.18 + depth * 0.16
        local size = depth
        shade(paper, depth == 3 and 1 or 2, 0.35 + depth * 0.2)
        for i = 0, count do
          local hx = (i * 2654435761 + depth * 7919) % 4294967296
          local x = math.floor((math.floor(hx / 65536) % w)
            + 5 * math.sin((t + i * 37) / (30 + depth * 10)))
          local y = math.floor((t * speed + i * 23 + depth * 11) % (h + 10))
          love.graphics.rectangle("fill", x % w, y, size, size)
        end
      end
    elseif pattern == "NIGHT" then
      -- Stars, a few of them twinkling out of phase with each other.
      -- `(i * 53) % w` with `(i * 37) % h` is a lattice, not a sky: the
      -- stars marched in diagonal columns. Hashing the index scatters
      -- them, and a moon gives the eye somewhere to land.
      -- the same crescent the city sky gets: a disc, then the night's own
      -- colour cutting it. Built from rectangles it came out a domino.
      shade(paper, 4, 0.9)
      disc(30, 24, 12)
      shade(paper, 1, 1)
      disc(36, 20, 12)
      for i = 1, 59 do
        local hx = (i * 2654435761) % 4294967296
        local x = math.floor(hx / 65536) % w
        local y = math.floor(hx / 7) % h
        -- clamped: an alpha below zero is not a fainter star, it is an
        -- undefined colour the renderer is entitled to do anything with
        local tw = math.max(0.05, 0.35 + 0.5 * math.sin((t + i * 61) / 30))
        shade(paper, 4, tw)
        if i % 9 == 0 then
          -- the bright ones get a cross, the way a twinkle is drawn
          love.graphics.rectangle("fill", x - 1, y, 3, 1)
          love.graphics.rectangle("fill", x, y - 1, 1, 3)
        else
          love.graphics.rectangle("fill", x, y, 1, 1)
        end
      end
    elseif pattern == "90S" then
      -- Two layers of shapes going opposite ways: the big ones behind,
      -- slowly, right to left; the small ones in front, quickly, left to
      -- right. That crossing IS the pattern -- one sheet of confetti
      -- sliding is a screensaver, two passing each other has depth.
      local function shape(kind, x, y, size, tone, alpha)
        shade(paper, tone, alpha)
        if kind == 0 then
          -- triangle
          poly("fill", x, y + size, x + size, y - size,
            x + size * 2, y + size)
        elseif kind == 1 then
          -- circle
          disc(x + size, y, size)
        elseif kind == 2 then
          -- zigzag, the lightning bolt off every 1994 pencil case
          for k = 0, 3 do
            love.graphics.rectangle("fill", x + k * size, y - size + k * size,
              size, size)
            love.graphics.rectangle("fill", x + k * size, y + k * size, size, size)
          end
        elseif kind == 3 then
          -- squiggle: three steps of a wave
          for k = 0, 5 do
            local dy = math.floor(math.sin(k * 1.1) * size)
            love.graphics.rectangle("fill", x + k * size, y + dy, size, size)
          end
        else
          -- cross / star
          love.graphics.rectangle("fill", x, y - size, size * 3, size)
          love.graphics.rectangle("fill", x + size, y - size * 2, size, size * 3)
        end
      end

      -- a band of colour across the middle, because everything in 1994 had
      -- one: it sits still while both layers cross it
      shade(paper, 3, 0.35)
      for x = 0, w, 8 do
        local dy = math.floor(math.sin((x + 20) / 18) * 5)
        love.graphics.rectangle("fill", x, h / 2 + dy - 8, 8, 16)
      end

      -- behind: BIG, slow, right to left
      for i = 0, 11 do
        local y = 14 + ((i * 41) % (h - 28))
        local x = w - (((t * 0.22 + i * 47) % (w + 90)) - 45)
        shape(i % 5, x, y, 6, 3, 0.75)
      end
      -- in front: smaller, quicker, left to right, in the loud colour
      for i = 0, 17 do
        local y = 8 + ((i * 31) % (h - 16))
        local x = ((t * 0.55 + i * 37) % (w + 60)) - 30
        shape((i + 2) % 5, x, y, 4, 2, 1)
      end
      -- and a few dots that stay put, so the eye has something still to
      -- measure the movement against
      shade(paper, 4, 0.35)
      for i = 0, 23 do
        local hx = (i * 2654435761) % 4294967296
        love.graphics.rectangle("fill", math.floor(hx / 65536) % w,
          math.floor(hx / 19) % h, 2, 2)
      end

    elseif pattern == "DESERT" then
      -- Late afternoon rather than noon: the sun low and huge, the dunes
      -- reading as bands of light and shade, and the air over the sand
      -- moving. A desert at midday is a flat orange rectangle, which is a
      -- colour and not a place.
      local horizon = math.floor(h * 0.46)

      -- the sun, sitting ON the horizon and cut by it
      shade(paper, 2, 0.85)
      disc(math.floor(w * 0.68), horizon - 6, 18)
      -- three bars across it, the way a low sun reads through haze
      for i = 0, 2 do
        shade(paper, 1, 0.5)
        love.graphics.rectangle("fill", math.floor(w * 0.68) - 20,
          horizon - 14 + i * 6, 40, 2)
      end

      -- dunes: four ranks of smooth crest, each one lower, darker and
      -- rougher than the one behind it, so the sand has distance in it
      for rank = 0, 3 do
        local base = horizon + 6 + rank * math.floor((h - horizon) / 5)
        shade(paper, 2 + math.min(2, rank), 0.55 + rank * 0.15)
        ridge(w, h, base, 4 + rank * 2, rank * 31 + 5, 2)
        -- the lit crest: a pale line following the same profile, one
        -- pixel up, which is what makes a dune a shape and not a blob
        shade(paper, 1, 0.35 - rank * 0.07)
        for x = 0, w, 2 do
          local hx = ((x + rank * 31 + 5) * 2654435761) % 4294967296
          local jitter = (math.floor(hx / 65536) % 5) - 2
          local y = base
            - math.floor((4 + rank * 2) * math.sin((x + (rank * 31 + 5) * 7) / 37))
            - math.floor((4 + rank * 2) * 0.45 * math.sin((x + (rank * 31 + 5) * 13) / 11))
            + jitter
          love.graphics.rectangle("fill", x, y, 2, 1)
        end
      end

      -- cacti, on the second rank so they have sand in front of them
      for i = 0, 3 do
        local hx = (i * 2246822519) % 4294967296
        local x = (math.floor(hx / 65536) % (w - 20)) + 6
        local y = horizon + 14 + (i % 2) * 8
        local tall = 10 + i * 3
        shade(paper, 4, 0.8)
        love.graphics.rectangle("fill", x, y - tall, 3, tall)
        love.graphics.rectangle("fill", x - 4, y - tall + 4, 4, 2)
        love.graphics.rectangle("fill", x - 4, y - tall + 4, 2, 5)
        love.graphics.rectangle("fill", x + 3, y - tall + 7, 4, 2)
        love.graphics.rectangle("fill", x + 5, y - tall + 3, 2, 6)
      end

      -- the air over the sand: short pale lines that slide and fade, which
      -- is the whole reason this scene is not still
      for i = 0, 13 do
        local y = horizon + 4 + ((i * 13) % (h - horizon - 8))
        local phase = math.sin((t + i * 29) / 26)
        local x = ((t * 0.3 + i * 41) % (w + 30)) - 15
        shade(paper, 1, 0.18 + 0.12 * phase)
        love.graphics.rectangle("fill", x, y, 10 + i % 7, 1)
      end

    elseif pattern == "VOLCANO" then
      -- The palette runs dark-first like NIGHT, so shade 1 is the rock and
      -- shade 4 is the fire. What makes it a volcano rather than a dark
      -- cave is that the light comes from BELOW: the glow is on the
      -- underside of everything.
      local floor = math.floor(h * 0.72)

      -- the sky, banded, lighter towards the crater
      for i = 0, 5 do
        shade(paper, 2, 0.25 + i * 0.09)
        love.graphics.rectangle("fill", 0, floor - (i + 1) * 8, w, 8)
      end

      -- two ridges, the far one paler, both drawn as a profile rather
      -- than as a row of triangles
      for rank = 0, 1 do
        local base = floor - 18 + rank * 10
        shade(paper, rank == 0 and 2 or 1, rank == 0 and 0.8 or 1)
        ridge(w, h, base, 9 + rank * 5, rank * 47 + 11, 2)
      end

      -- the lava: orange, not cream. The pale tone is the LIGHT on it --
      -- a bright line where it meets the rock and a shimmer that moves --
      -- and using it for the whole pool made a beach.
      shade(paper, 3, 1)
      love.graphics.rectangle("fill", 0, floor, w, h - floor)
      for i = 0, 5 do
        local y = floor + 3 + i * 4
        local x = ((t * (0.5 + i * 0.15) + i * 37) % (w + 60)) - 30
        shade(paper, 4, 0.55 - i * 0.07)
        love.graphics.rectangle("fill", x, y, 26 + i * 6, 2)
      end
      shade(paper, 4, 0.9)
      love.graphics.rectangle("fill", 0, floor, w, 2)
      for i = 0, 9 do
        local hx = (i * 2246822519) % 4294967296
        local x = ((t * 0.12 + math.floor(hx / 65536)) % (w + 40)) - 20
        local y = floor + 4 + (math.floor(hx / 37) % math.max(1, h - floor - 6))
        shade(paper, 1, 0.85)
        love.graphics.rectangle("fill", x, y, 12 + i % 9, 3)
      end

      -- embers, rising and drifting, brightest near the lava
      for i = 0, 21 do
        local hx = (i * 2654435761) % 4294967296
        local span = floor + 10
        local rise = (t * (0.25 + (i % 4) * 0.08) + i * 23) % span
        local y = floor + 6 - rise
        local x = (math.floor(hx / 65536) % w)
          + math.floor(math.sin((t + i * 31) / 22) * 6)
        local life = 1 - (rise / span)
        shade(paper, 4, 0.15 + 0.75 * life)
        love.graphics.rectangle("fill", x % w, y, 1 + (i % 3 == 0 and 1 or 0),
          1 + (i % 3 == 0 and 1 or 0))
      end

    elseif pattern == "SPACE" then
      -- Dark-first palette again. Stars in three depths so the field has
      -- some distance in it, one planet with a lit limb, and a nebula that
      -- drifts across rather than sitting there being a gradient.
      for depth = 1, 3 do
        local count = 18 + depth * 12
        for i = 0, count do
          local hx = (i * 2654435761 + depth * 7919) % 4294967296
          local x = (math.floor(hx / 65536) + math.floor(t * 0.04 * depth)) % w
          local y = math.floor(hx / 11) % h
          local tw = 0.35 + 0.45 * math.sin((t + i * 47) / (18 + depth * 9))
          shade(paper, depth == 3 and 4 or 3, math.max(0.08, tw * depth / 3))
          love.graphics.rectangle("fill", x, y, depth == 3 and 2 or 1,
            depth == 3 and 2 or 1)
        end
      end

      -- the nebula: three soft bands crossing slowly, in the mid tones so
      -- the stars stay on top of it
      for i = 0, 2 do
        local y = 16 + i * math.floor(h / 4)
        local x = ((t * (0.06 + i * 0.03) + i * 53) % (w + 120)) - 60
        shade(paper, 2, 0.5 - i * 0.1)
        for k = 0, 5 do
          local band = 10 + k * 3
          love.graphics.rectangle("fill", x - band * 2, y + k * 3,
            band * 6, 3)
        end
      end

      -- a planet, low and to one side, with its lit edge towards the light
      local px, py, pr = math.floor(w * 0.24), math.floor(h * 0.68), 22
      shade(paper, 2, 1)
      disc(px, py, pr)
      shade(paper, 3, 0.9)
      disc(px + 5, py - 4, pr - 5)
      shade(paper, 1, 1)
      disc(px + 12, py - 9, pr - 4)
      -- a ring, flattened: two bars either side rather than an ellipse
      shade(paper, 4, 0.55)
      love.graphics.rectangle("fill", px - pr - 8, py + 3, pr + 4, 2)
      love.graphics.rectangle("fill", px + 6, py + 3, pr + 4, 2)

    elseif pattern == "SAKURA" then
      -- A cherry tree from underneath, which is how anyone actually looks
      -- at one: the branch across the top of the frame, the blossom
      -- hanging off it, and the petals coming down the whole screen. The
      -- ground is water, because a still surface doubles the tree for
      -- free and gives the bottom of the screen something to do.
      local waterY = math.floor(h * 0.74)

      -- the water: a real step down in tone from the sky, or the two
      -- halves of the screen read as one pink field with a line in it
      shade(paper, 3, 0.75)
      love.graphics.rectangle("fill", 0, waterY, w, h - waterY)
      shade(paper, 4, 0.5)
      love.graphics.rectangle("fill", 0, waterY, w, 2)
      -- the tree, upside down, in the water
      for i = 0, 9 do
        local hx = (i * 2654435761) % 4294967296
        local cx = math.floor(hx / 65536) % w
        shade(paper, 2, 0.35)
        disc(cx, waterY + 6 + (i % 3) * 4, 3 + (i % 2))
      end
      -- ripples: short pale dashes that slide, so the water reads as wet
      for i = 0, 11 do
        local y = waterY + 5 + (i * 5) % math.max(1, h - waterY - 6)
        local x = ((t * 0.22 + i * 43) % (w + 40)) - 20
        shade(paper, 1, 0.5 - (i % 4) * 0.08)
        love.graphics.rectangle("fill", x, y, 12 + (i % 5) * 4, 1)
      end

      -- the branch: one thick limb across the top with a few boughs off it
      shade(paper, 4, 0.9)
      love.graphics.rectangle("fill", 0, 10, w, 5)
      for i = 0, 4 do
        local bx = 14 + i * math.floor(w / 5)
        local drop = 8 + (i % 3) * 7
        love.graphics.rectangle("fill", bx, 14, 3, drop)
        love.graphics.rectangle("fill", bx - 6 + (i % 2) * 10, 14 + drop, 8, 2)
      end

      -- blossom: clusters of small discs hanging off the branch, the
      -- whole canopy swaying together rather than each clump on its own
      local sway = math.sin(t / 70) * 3
      for i = 0, 23 do
        local hx = (i * 2654435761) % 4294967296
        local cx = (math.floor(hx / 65536) % w)
        local cy = 12 + math.floor(hx / 4096) % 34
        local r = 3 + (i % 3)
        -- an edge in the deep tone, the body in the mid one and a
        -- highlight in the pale one: three tones is what stops a cluster
        -- of blossom being a pink smudge on a pink sky
        shade(paper, 3, 0.8)
        disc(cx + math.floor(sway), cy, r + 1)
        shade(paper, 2, 1)
        disc(cx + math.floor(sway), cy, r)
        shade(paper, 1, 0.95)
        disc(cx + math.floor(sway) - 1, cy - 1, math.max(1, r - 2))
      end

      -- petals, falling and drifting sideways, three sizes
      for i = 0, 25 do
        local hx = (i * 2246822519) % 4294967296
        local speed = 0.18 + (i % 4) * 0.09
        local y = ((t * speed + i * 19) % (h + 12)) - 6
        local x = (math.floor(hx / 65536) % w)
          + math.floor(math.sin((t + i * 27) / 30) * (5 + i % 6))
        shade(paper, 2, 0.9)
        love.graphics.rectangle("fill", x % w, y, 2, 1 + (i % 2))
        if i % 5 == 0 then
          shade(paper, 3, 0.6)
          love.graphics.rectangle("fill", x % w, y + 1, 1, 1)
        end
      end

    elseif pattern == "AURORA" then
      -- Dark-first palette: the sky is shade 1 and the light is shade 4.
      -- The aurora is not a band of colour, it is CURTAINS -- vertical
      -- ribs of different heights whose tops move independently -- and
      -- that is the only thing that makes it read as an aurora rather
      -- than as a gradient.
      local snowY = math.floor(h * 0.80)

      -- stars first, so the curtains hang in front of them
      for i = 0, 39 do
        local hx = (i * 2654435761) % 4294967296
        local x = math.floor(hx / 65536) % w
        local y = math.floor(hx / 13) % snowY
        shade(paper, 4, 0.25 + 0.35 * math.sin((t + i * 51) / 160))
        love.graphics.rectangle("fill", x, y, 1, 1)
      end

      -- three curtains, each drifting at its own speed. A QUARTER of what
      -- they first ran at: an aurora that crosses the frame in a few
      -- seconds is a screensaver, and the real thing is something you
      -- notice has changed rather than something you watch move.
      for band = 0, 2 do
        local speed = 0.025 + band * 0.0125
        local baseY = 26 + band * 16
        for x = 0, w, 3 do
          local phase = (x + t * speed * 10) / 26
          local tall = 22 + band * 10
            + math.floor(math.sin(phase) * 12)
            + math.floor(math.sin(phase * 0.37 + band) * 7)
          local top = baseY - math.floor(tall / 2)
          -- the ribbon is brightest at its foot and fades upward, which
          -- is the way the real thing goes
          for k = 0, tall do
            local y = top + k
            if y > 0 and y < snowY then
              local fade = k / tall
              shade(paper, fade > 0.55 and 3 or 4,
                (0.10 + 0.55 * fade) * (0.7 + 0.3 * math.sin(phase * 2)))
              love.graphics.rectangle("fill", x, y, 3, 1)
            end
          end
        end
      end

      -- the snow field under it, and the light lying on it
      shade(paper, 2, 1)
      love.graphics.rectangle("fill", 0, snowY, w, h - snowY)
      shade(paper, 3, 0.35)
      love.graphics.rectangle("fill", 0, snowY, w, 2)
      for i = 0, 7 do
        local x = ((t * 0.1 + i * 37) % (w + 30)) - 15
        shade(paper, 3, 0.18)
        love.graphics.rectangle("fill", x, snowY + 3 + (i % 3) * 4, 24, 1)
      end

    elseif pattern == "STORM" then
      -- Everything in here runs at a QUARTER of what it first shipped at.
      -- Rain drawn at a plausible speed on a 160-pixel screen is not rain,
      -- it is static: the drops cross the frame before the eye resolves
      -- them. Slowed down you watch individual drops fall, which is what
      -- weather looks like through a window.
      local st = t / 4
      -- Rain has to be rain and not hatching: three depths, each at its
      -- own angle and speed, with the near drops longer. The lightning is
      -- rare and short -- a flash you catch out of the corner of the eye
      -- rather than a strobe -- because a box screen is somewhere you sit
      -- for a while.
      local groundY = math.floor(h * 0.86)

      -- cloud bank across the top, two ranks, drifting
      for rank = 0, 1 do
        local y = 4 + rank * 14
        for i = 0, 5 do
          local x = ((st * (0.08 + rank * 0.05) + i * 41) % (w + 70)) - 35
          shade(paper, 3 - rank, 0.75)
          disc(x + 14, y + 10, 12 - rank * 2)
          disc(x + 26, y + 12, 9 - rank)
          disc(x + 4, y + 12, 8 - rank)
          love.graphics.rectangle("fill", x, y + 10, 34, 8 - rank * 2)
        end
      end

      -- the flash: a whole-screen lift plus a bolt, on a long cycle
      local cycle = (st % 240)
      if cycle < 6 then
        shade(paper, 1, cycle < 3 and 0.55 or 0.25)
        love.graphics.rectangle("fill", 0, 0, w, h)
        shade(paper, 1, 0.95)
        local bx = 40 + (math.floor(st / 240) * 37) % math.max(1, w - 80)
        local by = 22
        for seg = 0, 5 do
          local nx = bx + ((seg % 2 == 0) and 6 or -5)
          local ny = by + 9
          love.graphics.rectangle("fill", math.min(bx, nx), by,
            math.abs(nx - bx) + 2, 2)
          love.graphics.rectangle("fill", nx, by, 2, 9)
          bx, by = nx, ny
        end
      end

      -- rain, three depths
      for depth = 1, 3 do
        local count = 14 + depth * 10
        local speed = 1.6 + depth * 1.4
        local slant = 2 + depth
        local length = 3 + depth * 2
        shade(paper, depth == 3 and 3 or 2, 0.25 + depth * 0.2)
        for i = 0, count do
          local hx = (i * 2654435761 + depth * 7919) % 4294967296
          local fall = (st * speed + i * 29) % (h + length * 4)
          local y = fall - length * 2
          local x = ((math.floor(hx / 65536) % w) - fall * slant / 8) % w
          love.graphics.rectangle("fill", x, y, 1, length)
        end
      end

      -- the ground, and the drops bouncing off it
      shade(paper, 4, 0.9)
      love.graphics.rectangle("fill", 0, groundY, w, h - groundY)
      for i = 0, 9 do
        local hx = (i * 2246822519) % 4294967296
        local phase = (st * 0.6 + i * 13) % 30
        if phase < 6 then
          local x = math.floor(hx / 65536) % w
          shade(paper, 2, 0.6 - phase * 0.08)
          love.graphics.rectangle("fill", x - math.floor(phase), groundY - 2, 1, 1)
          love.graphics.rectangle("fill", x + math.floor(phase), groundY - 2, 1, 1)
        end
      end

    elseif pattern == "CIRCUIT" then
      -- A board seen close up: traces that turn at right angles, pads
      -- where they end, and a charge running ALONG a trace rather than a
      -- glow sitting on top of it. Dark-first palette, so the traces are
      -- the light end.
      local pitch = 16
      local cols = math.ceil(w / pitch) + 1
      local rowsN = math.ceil(h / pitch) + 1

      -- the board itself, with its own quiet texture
      shade(paper, 2, 0.25)
      for y = 0, h, 4 do
        love.graphics.rectangle("fill", 0, y, w, 1)
      end

      -- traces: each cell picks a shape from its own hash, so the board
      -- is fixed rather than random every frame
      for cy = 0, rowsN do
        for cx = 0, cols do
          -- no bitwise XOR here: this file runs on LuaJIT, which is
          -- 5.1, and `~` is a syntax error there rather than an operator
          local hx = (cx * 73856093 + cy * 19349663 + cx * cy * 83492791)
            % 4294967296
          local kind = math.floor(hx / 4096) % 4
          local x, y = cx * pitch, cy * pitch
          shade(paper, 3, 0.55)
          if kind == 0 then
            love.graphics.rectangle("fill", x, y + 7, pitch, 2)
          elseif kind == 1 then
            love.graphics.rectangle("fill", x + 7, y, 2, pitch)
          elseif kind == 2 then
            love.graphics.rectangle("fill", x, y + 7, 9, 2)
            love.graphics.rectangle("fill", x + 7, y + 7, 2, pitch - 7)
          else
            love.graphics.rectangle("fill", x + 7, y, 2, 9)
            love.graphics.rectangle("fill", x + 7, y + 7, pitch - 7, 2)
          end
          -- a pad every so often, which is where a trace stops
          if kind == 3 and (cx + cy) % 3 == 0 then
            shade(paper, 3, 0.8)
            love.graphics.rectangle("fill", x + 4, y + 4, 8, 8)
            shade(paper, 1, 1)
            love.graphics.rectangle("fill", x + 6, y + 6, 4, 4)
          end
        end
      end

      -- the charge: bright cells travelling along the horizontal traces
      for i = 0, 5 do
        local lane = (i * 3 + 1) % rowsN
        local speed = 0.6 + (i % 3) * 0.35
        local x = ((t * speed + i * 53) % (w + 40)) - 20
        local y = lane * pitch + 7
        for k = 0, 6 do
          shade(paper, 4, 0.9 - k * 0.13)
          love.graphics.rectangle("fill", x - k * 3, y, 3, 2)
        end
      end
      -- and a couple going down instead, so it is a board and not a belt
      for i = 0, 2 do
        local lane = (i * 5 + 2) % cols
        local y = ((t * (0.5 + i * 0.2) + i * 71) % (h + 30)) - 15
        local x = lane * pitch + 7
        for k = 0, 5 do
          shade(paper, 4, 0.85 - k * 0.14)
          love.graphics.rectangle("fill", x, y - k * 3, 2, 3)
        end
      end

    elseif pattern == "TRAIN" then
      -- The view out of a window at speed, which is a scene where the
      -- MOTION is the subject: poles snapping past, hills turning slowly,
      -- wires dipping between the poles. Three speeds is the whole trick.
      local sillY = math.floor(h * 0.82)
      local skyY = 8

      -- sky, and MOUNTAINS beyond it rather than rolling hills. What a
      -- train window frames is distance, and rounded green humps read as
      -- a park: peaks with snow on them read as somewhere you are being
      -- carried through.
      shade(paper, 1, 1)
      love.graphics.rectangle("fill", 0, skyY, w, sillY - skyY)
      for rank = 0, 2 do
        local base = sillY - 30 + rank * 12
        local amp = 20 - rank * 5
        local drift = t * (0.03 + rank * 0.05)
        shade(paper, 2 + math.min(1, rank), 0.65 + rank * 0.2)
        for x = 0, w, 2 do
          local hx = ((x + math.floor(drift) + rank * 131) * 2654435761) % 4294967296
          local jitter = (math.floor(hx / 65536) % 4) - 2
          -- TRIANGLES, not sines: a sine gives a rounded hump, and a
          -- range of humps is a park. Two triangle waves of different
          -- periods give summits with straight sides and a saddle
          -- between them, which is what a mountain reads as at this size.
          local function tri(period, phase)
            local u = ((x + drift + phase) % period) / period
            return 1 - math.abs(u * 2 - 1)
          end
          local y = base
            - math.floor(amp * tri(97 + rank * 23, rank * 31))
            - math.floor(amp * 0.55 * tri(31 + rank * 7, rank * 17))
            + jitter
          love.graphics.rectangle("fill", x, y, 2, sillY - y)
          -- snow on the far range only, where the summit is high enough
          if rank == 0 and (base - y) > amp * 0.55 then
            shade(paper, 1, 0.85)
            love.graphics.rectangle("fill", x, y, 2, 3)
            shade(paper, 2, 0.65)
          end
        end
      end

      -- the wires: two catenaries sagging between the poles. The spacing
      -- was 46 and the poles read as a fence: on a 160-pixel screen that
      -- is four of them in frame at once, which is a picket, not a line
      -- being travelled along.
      local spacing = 96
      local offset = (t * 1.7) % spacing
      for pole = -1, math.ceil(w / spacing) + 1 do
        local px2 = pole * spacing - offset
        for wire = 0, 1 do
          shade(paper, 4, 0.5 - wire * 0.15)
          for x = 0, spacing do
            local sag = math.sin(x / spacing * math.pi) * (6 + wire * 4)
            love.graphics.rectangle("fill", px2 + x, 14 + wire * 7 + sag, 1, 1)
          end
        end
        -- the pole itself, the fastest thing on the screen
        shade(paper, 4, 0.9)
        love.graphics.rectangle("fill", px2, 10, 3, sillY - 10)
        love.graphics.rectangle("fill", px2 - 5, 12, 13, 2)
      end

      -- the sill, and the frame of the window
      shade(paper, 4, 1)
      love.graphics.rectangle("fill", 0, sillY, w, h - sillY)
      shade(paper, 3, 1)
      love.graphics.rectangle("fill", 0, sillY, w, 3)
      shade(paper, 4, 1)
      love.graphics.rectangle("fill", 0, 0, w, skyY)
      -- rain on the glass, running back with the airflow
      for i = 0, 11 do
        local hx = (i * 2246822519) % 4294967296
        local x = math.floor(hx / 65536) % w
        local y = skyY + ((t * (0.9 + (i % 3) * 0.5) + i * 23) % (sillY - skyY))
        shade(paper, 1, 0.35)
        love.graphics.rectangle("fill", x, y, 1, 4 + (i % 3))
      end

    elseif pattern == "CASTLE" then
      -- Inside, not outside: a stone wall, an arched window with weather
      -- behind it, and torches. The motion is the flame and what the
      -- window shows, because a wall that moves is not a wall.
      local course = 12
      for row = 0, math.ceil(h / course) do
        local y = row * course
        local offset = (row % 2) * 14
        for x = -14, w, 28 do
          local hx = ((x + row * 131) * 2654435761) % 4294967296
          shade(paper, 2 + math.floor(hx / 65536) % 2, 0.55)
          love.graphics.rectangle("fill", x + offset + 1, y + 1, 26, course - 2)
        end
      end
      -- the mortar reading as lines between the courses
      shade(paper, 4, 0.35)
      for row = 0, math.ceil(h / course) do
        love.graphics.rectangle("fill", 0, row * course, w, 1)
      end

      -- the window: an arch of sky, with rain crossing it
      local wx, wy, ww, wh2 = math.floor(w * 0.62), 18, 34, 46
      shade(paper, 4, 0.9)
      love.graphics.rectangle("fill", wx - 3, wy - 3, ww + 6, wh2 + 6)
      shade(paper, 1, 1)
      love.graphics.rectangle("fill", wx, wy + 10, ww, wh2 - 10)
      disc(wx + math.floor(ww / 2), wy + 10, math.floor(ww / 2))
      for i = 0, 15 do
        local rx = wx + ((i * 13 + math.floor(t * 0.9)) % ww)
        local ry = wy + 2 + ((i * 17 + math.floor(t * 1.7)) % (wh2 - 4))
        shade(paper, 2, 0.7)
        love.graphics.rectangle("fill", rx, ry, 1, 3)
      end
      -- the bars
      shade(paper, 4, 0.8)
      for i = 1, 3 do
        love.graphics.rectangle("fill", wx + i * math.floor(ww / 4), wy, 2, wh2)
      end

      -- two torches, flickering out of phase
      for i = 0, 1 do
        local tx = math.floor(w * (0.16 + i * 0.16))
        local ty = math.floor(h * 0.42)
        shade(paper, 4, 0.9)
        love.graphics.rectangle("fill", tx, ty, 3, 12)
        local flick = math.sin((t + i * 37) / 9)
        local tall = 10 + math.floor(flick * 4)
        -- the glow first, so the flame sits in it rather than on it
        shade(paper, 1, 0.30 + 0.08 * flick)
        disc(tx + 1, ty - 6, 18)
        shade(paper, 1, 0.18 + 0.06 * flick)
        disc(tx + 1, ty - 6, 26)
        -- a flame on a pale wall can only read by being PALER: the body
        -- in the lightest tone, a mid-tone edge to give it a shape
        shade(paper, 2, 0.9)
        poly("fill", tx - 4, ty, tx + 1, ty - tall, tx + 6, ty)
        shade(paper, 1, 1)
        poly("fill", tx - 2, ty - 1, tx + 1, ty - tall + 4, tx + 4, ty - 1)
      end
    end

    love.graphics.setColor(0, 0, 0, 1)
  end

  -- ------- and it stays inside the screen
  --
  -- Every scene draws deliberately past its own edges: waves start at -8,
  -- the 90s shapes at -30, and a strip is tiled until it covers the width
  -- with the last copy hanging off the right. On a Gen 1 boot that costs
  -- nothing, because Game:draw asks the top state for a uiSize and gives
  -- the UI a canvas of exactly that size, which clips. Gold has no such
  -- hook -- src/core/Game2.lua composes states straight into a
  -- window-sized canvas under Chrome's scale -- so everything past the
  -- edge landed on the white surround AROUND the Game Boy screen.
  --
  -- Two attempts at this were made with the scissor and both were wrong,
  -- the second one badly: on Gold every wallpaper disappeared. A scissor
  -- is a rectangle in some other space than the one being drawn in, and
  -- working out WHICH space, through a chain of transforms, a canvas and
  -- a device pixel ratio, is a guess that cannot be tested from here.
  --
  -- So it does not guess. The scene is painted into a surface that is
  -- exactly the size of the screen and then blitted at the origin: a
  -- canvas has no coordinates outside itself, so what falls off the edge
  -- is gone by construction, on any boot, under any transform. If a
  -- canvas cannot be had the scene is painted straight to the screen as
  -- it always was -- spilling over the border is a blemish, and a blemish
  -- is better than a blank box.
  -- Kept per SIZE, not one at a time. A full-screen frame paints the
  -- backdrop at the canvas size, each panel at the panel size and the peek
  -- strip at a third -- so a single-slot cache threw its canvas away and
  -- built a new one three times a frame, for ever. Four sizes is every
  -- shape one frame asks for, and a fifth evicts the lot rather than
  -- growing without end.
  local paperSurfaces, paperSurfaceN = {}, 0
  local function surfaceFor(w, h)
    local key = w .. "x" .. h
    local hit = paperSurfaces[key]
    if hit ~= nil then return hit or nil end
    if paperSurfaceN >= 4 then paperSurfaces, paperSurfaceN = {}, 0 end
    local ok, made = pcall(love.graphics.newCanvas, w, h)
    local canvas = (ok and made) or false
    if canvas then pcall(canvas.setFilter, canvas, "nearest", "nearest") end
    paperSurfaces[key] = canvas
    paperSurfaceN = paperSurfaceN + 1
    return canvas or nil
  end

  local function onOwnSurface(w, h, paint)
    local g = love.graphics
    local canvas = g.newCanvas and surfaceFor(w, h)
    if not canvas then return paint() end
    local ok = pcall(function()
      local previous = g.getCanvas and g.getCanvas() or nil
      -- a canvas does not reset the transform, and the scene is drawn in
      -- its own coordinates from 0,0
      g.push()
      g.origin()
      g.setCanvas(canvas)
      g.clear(0, 0, 0, 0)
      paint()
      g.setCanvas(previous)
      g.pop()
      g.setColor(1, 1, 1, 1)
      g.draw(canvas, 0, 0)
    end)
    -- a canvas that failed mid-way has left the target where it found it
    -- (setCanvas is inside the pcall), so the fallback is the same draw
    -- again rather than a frame with a hole in it
    if not ok then
      pcall(g.setCanvas)
      paint()
    end
  end

  -- BIG is the same screen at twice the pixel density -- a 56-pixel cell
  -- is a 28-pixel cell doubled -- so a scene meant for 160x144 belongs on
  -- it at scale two, not stretched and not taught a second geometry. What
  -- shipped instead drew the scene at its literal size in a canvas twice
  -- as wide: a town in one corner of the box and white everywhere else.
  --
  -- Scaling rather than re-deriving every count is also the only version
  -- of this that stays true: one scene, one composition, and the pixels
  -- stay square because the factor is a whole number.
  -- A style may carry its OWN four colours. That is what lets a place
  -- have more than one hand drawn here: SAKURA by day and SAKURA at
  -- night are the same scene through two palettes, and the menu lists
  -- them as two entries because that is what they are to a player.
  local function reshade(paper, style)
    if not (style and paper and (style.palette or style.pattern)) then
      return paper
    end
    return {
      id = paper.id,
      pattern = style.pattern or paper.pattern,
      palette = style.palette or paper.palette,
    }
  end

  local function drawWallpaper(paper, w, h, style, tick)
    paper = reshade(paper, style)
    if paper.pattern == "PLAIN" or not paper.palette then return end
    local t = animateOn() and (tick or 0) or 0
    -- someone else's art first: if it draws, this function is done
    if style and (style.layers or style.image) then
      local drew = false
      onOwnSurface(w, h, function() drew = drawArt(style, w, h, t) end)
      if drew then return end
    end

    onOwnSurface(w, h, function()
      local k = math.max(1, math.floor(math.min(w / 160, h / 144)))
      local scaled = k > 1 and pcall(function()
        love.graphics.push()
        love.graphics.scale(k, k)
      end)
      -- if the transform did not take, draw at the real size rather than
      -- at a size nothing is applying: a corner of a scene is worse than
      -- a sparse one
      if not scaled then k = 1 end
      drawPattern(paper, w / k, h / k, t)
      if scaled then pcall(love.graphics.pop) end
    end)
  end

  -- Exposed for the same reason picScale and spriteToDraw are: a pattern
  -- is the one part of this screen nobody can judge by reading it, and a
  -- harness that stubs love.graphics can render one to a file and LOOK.

  -- The seam another mod draws through: same scenes, same artists, art
  -- shipped once. gen1recomp-gen3-dex calls this with its own size.
  mod.exports.paintWallpaper = drawWallpaper
  mod.exports.reshadeWallpaper = reshade

  local function newScreen(game)
    Boxes.ensure(game.save)

    local self = {
      game = game,
      isOpaque = true,   -- a full-screen replacement: nothing under it draws
      mode = "box",      -- "box" | "party"
      col = 0, row = 0,  -- zero-based, so the modulo wrap below is honest
      held = nil,        -- { mon = ..., from = "box"|"party" }
      notice = nil,
      noticeAt = 0,
      -- the header row (see "the control scheme" in PLAN.md): the cursor
      -- rises out of the grid onto the box title. Only reachable in "box"
      -- mode -- the party pane has no header.
      header = false,
      -- SORT's one-deep undo: a snapshot of the box as it stood right
      -- before the last sort, kept only while this screen is open.
      sortUndo = nil,    -- { boxNum = ..., mons = { ... } }
      -- FIND's remembered query, for as long as this screen is open. FIND
      -- NEXT (a box-menu row, and START on the header) re-runs this.
      findQuery = nil,   -- { kind = "species"|"type"|"mark", value = ... }
      -- MARK MODE: A opens the marking window instead of grabbing, B leaves
      -- the mode rather than the screen.
      markMode = false,
      -- MOVE MANY: which slots of which box are ticked. Keyed by box number
      -- so ticking in one box and walking to another does not silently
      -- carry a selection that no longer points at anything.
      manyBox = nil,
      many = {},
      markWindow = nil,  -- { mon = ..., cursor = 1 } while the window is open
      -- Wilds of Kanto's resolve() per MON (see owSpriteFor), for the life of this
      -- screen (see "overworld sprites from Wilds of Kanto" below). A
      -- sprite table, or `false` for a cached miss -- never nil, so a miss
      -- is remembered rather than re-asked every draw.
      -- Weak keys: entries are keyed by the mon table itself (see
      -- owSpriteFor), so a Pokemon that leaves the box while this screen is
      -- open must not be kept alive by its own cache row.
      owSpriteCache = setmetatable({}, { __mode = "k" }),
    }

    -- ------- the surface this screen wants
    --
    -- Game:draw asks the TOP state for its size before anything is drawn,
    -- and passes 160x144 when the state has no opinion. So this is the
    -- whole mechanism: no enter hook, no restore on exit, and no way to
    -- leave the rest of the game wearing a canvas it did not ask for.
    function self:uiSize()
      local L = layout(game)
      return L.w, L.h
    end

    -- ------- FULL SCREEN on Gold
    --
    -- Game2 never asks a state how big it would like to be, so uiSize is
    -- dead there. What it DOES have is drawsWidescreen/drawWidescreen: a
    -- state that says yes gets handed the window and draws itself over it.
    -- gen3_dex has used that pair since its BIG landed; this is the same
    -- twelve lines, fitting this screen's own surface at a whole scale and
    -- centring it, with self:draw() drawing exactly what it draws anywhere
    -- else.
    -- Gen 1's own way of saying "do not letterbox me": Game:draw walks the
    -- whole stack for this (Game.fillScaleInStack), so it keeps holding
    -- while a menu or a text box is open over the grid.
    function self:wantsFillScale()
      return fullOn() and not isGen2(game)
    end

    function self:drawsWidescreen()
      return isGen2(game) and fullOn()
    end

    function self:drawWidescreen(winW, winH)
      local L = layout(game)
      -- Recorded for the touch layer: on Gold this screen applies its OWN
      -- translate and scale, so this is the only place that knows how a
      -- window point maps back onto the surface the cells were laid out
      -- on. Written every frame it draws, read by toUI below.
      self.touchXform = nil
      -- FULL fills; BIG stays on whole pixels.
      --
      -- Flooring the ratio is right for BIG, a fixed 320x288 that wants
      -- crisp whole pixels. It is wrong for FULL, whose size is already
      -- chosen to suit the window: fullLayout answers a whole number of
      -- PANELS, so on a 405-wide window it returns 296 -- a ratio of 1.37,
      -- floored to 1. Gold then drew the screen at life size in the middle
      -- of the window with a white band down each side, while Gen 1 -- where
      -- the same layout goes through uiSize() and the renderer fits it --
      -- filled the glass. Same option, same layout, two different pictures,
      -- and the reason was this one floor.
      local fit = math.min(winW / L.w, winH / L.h)
      local scale = L.full and fit or math.max(1, math.floor(fit))
      local ox = math.floor((winW - L.w * scale) / 2)
      local oy = math.floor((winH - L.h * scale) / 2)
      self.touchXform = { ox = ox, oy = oy, sx = scale, sy = scale }
      love.graphics.push()
      love.graphics.translate(ox, oy)
      love.graphics.scale(scale, scale)
      self:draw()
      love.graphics.pop()
    end

    -- ------- A WINDOW POINT, BROUGHT ONTO THE SURFACE THE CELLS ARE ON
    --
    -- This is the piece the first cut of touch was missing, and it is the
    -- same lesson the scissor taught: a coordinate is worth nothing until
    -- you know which space it is in.
    --
    -- `ev.x/y` are LOVE window units, and so are `gameX/gameY` -- the
    -- viewport only ever SUBTRACTS an origin from them
    -- (src/render/GameViewport.lua:127-133, no scaling anywhere). The cells
    -- are laid out on this screen's own surface, which is 320x288 in BIG or
    -- the full layout's size, and something scales that surface into the
    -- window. Feeding window units to hitAt asks "which cell is at pixel
    -- 700 of a 296-wide screen", and the answer is nonsense.
    --
    -- Two scalers, so two answers. On Gold this screen scales itself, in
    -- drawWidescreen just above, and the numbers it used are recorded
    -- there. On Gen 1 the renderer does it, and frameRects hands back the
    -- UI surface's origin and draw scale -- `uox/uoy` and `Ux/Uy` -- which
    -- is exactly this transform read forwards.
    local function toUI(x, y)
      local t = self.touchXform
      if t and t.sx and t.sx > 0 and t.sy and t.sy > 0 then
        return (x - t.ox) / t.sx, (y - t.oy) / t.sy
      end
      local okR, Renderer = pcall(require, "src.render.Renderer")
      if not okR then return x, y end
      local ok, r = pcall(function() return Renderer:frameRects() end)
      if ok and type(r) == "table" and r.Ux and r.Ux > 0
         and r.Uy and r.Uy > 0 then
        return (x - (r.uox or 0)) / r.Ux, (y - (r.uoy or 0)) / r.Uy
      end
      -- no transform to be had: the raw point is the best guess there is,
      -- and on an unscaled 1:1 boot it is also the right one
      return x, y
    end
    self.toUI = toUI

    -- StateStack calls this on pop and only on pop -- a screen pushed ON TOP
    -- of this one (the summary) does not fire it -- so it is exactly "the
    -- player is done with the boxes" and nothing else.
    --
    -- Every box, not only the open one: a mon put away in box 3 an hour ago
    -- is as deposited as the one dropped a second ago, and "rested unless
    -- you happened to be looking at that box when you left" is not a rule
    -- anybody could hold in their head.
    -- ------- the follower has to be told the party changed
    --
    -- Reported: deposit a shiny that is following you, withdraw an ordinary
    -- Pokemon, close the screen -- and the follower behind you is still the
    -- shiny one until you change maps or step into a Pokemon Centre.
    --
    -- Nothing here was wrong about the party: it really did change. What was
    -- missing is that ANYTHING was said about it. This screen moves Pokemon
    -- with its own table operations rather than through the vanilla PC's
    -- flow, and the follower is spawned once and then left alone -- it is
    -- rebuilt on PikachuFollower.onMapEntered, which is exactly why walking
    -- through a door fixes it. A follower mod (Wilds of Kanto) reads the
    -- Pokemon at spawn time, so a stale entity keeps the old species, the
    -- old palette and the old shininess.
    --
    -- So: respawn it on the way out, with viaMapLoad FALSE -- the mid-map
    -- respawn the engine already uses for a bike dismount or a revive, which
    -- puts the follower on the cell behind the player rather than under him
    -- as a fresh map entry would.
    --
    -- `src.world.PikachuFollower` is one of the fifteen names the Gen 2
    -- adapter serves, resolving to src/world/gen2/Follower.lua on a Gold
    -- boot with the same onMapEntered signature, so this one call covers
    -- both games. The overworld is spelled differently between them, which
    -- is the only branch needed.
    local function refreshFollower()
      local ow = game.overworld or game.world
      if not ow then return end

      -- 1. The ENGINE's own follower (Yellow's Pikachu, and Gold's trailing
      --    companion). `src.world.PikachuFollower` is one of the fifteen
      --    names the Gen 2 adapter serves, resolving to
      --    src/world/gen2/Follower.lua with the same signature, so this one
      --    call covers both games. viaMapLoad = false is the mid-map
      --    respawn the engine uses for a bike dismount: the follower lands
      --    on the cell behind the player rather than under him.
      local ok, Follower = pcall(require, "src.world.PikachuFollower")
      if ok and type(Follower) == "table"
          and type(Follower.onMapEntered) == "function" then
        pcall(Follower.onMapEntered, game, ow, nil, false)
      end

      -- 2. Wilds of Kanto's follower, which is NOT the engine's.
      --
      -- 1.9.1 did only the call above and the report stayed open, for a
      -- reason worth writing down: that mod does not ride PikachuFollower
      -- at all. It keeps its own trailing entities and designates the
      -- follower through save data (`pokepcLeader` / `followerPartyIndex`)
      -- rather than party order, so respawning the engine's follower
      -- rebuilt something that was never the thing on screen.
      --
      -- Its own exported `syncAll(game, ow)` is the right seam and does
      -- exactly what a map change does -- which is what the reporter
      -- noticed fixes it: it removes the trailers, clears the player's
      -- cached control species, re-syncs the control visual and rebuilds
      -- the trailers with `mapEnter = true`.
      --
      -- Reached through the engine's own `mod.find`, not a manifest
      -- dependency, and every call guarded: with that mod absent this is
      -- one nil check, and if it ever renames the export we degrade to the
      -- engine follower rather than throwing on the way out of a screen.
      local okHandle, handle = pcall(mod.find, "overworld_wild_spawns")
      if not okHandle or not handle or not handle.exports then return end
      local syncAll = handle.exports.syncAll
      if type(syncAll) ~= "function" then return end

      -- ------- and where it comes back (issue #3, the second report)
      --
      -- 1.9.2 rebuilt the right follower and put it in the wrong place: it
      -- reappeared ON the player rather than behind him. That is not a
      -- choice this screen makes, it is what syncAll asks for -- it always
      -- calls syncTrailers with `mapEnter = true`
      -- (lib/follower/control_engine.lua:4056-4060), and a map entry with no
      -- walked trail behind it parks the pack on the player's own cell so it
      -- walks out from under him, the Red/Blue door-exit look
      -- (:2418-2432). Nobody walked anywhere while the box was open, so the
      -- trail is empty every time and that branch is the one that runs.
      --
      -- There is no "mid-map" mode on that export to ask for instead, so the
      -- cells are remembered before the rebuild and given back after it. The
      -- restore is deliberately narrow: only a trailer that came back
      -- standing exactly on the player is moved, which is the parked case
      -- and nothing else. A rebuild that changed the number of followers
      -- goes down that mod's own grow/trim path with its positions intact,
      -- and this leaves it alone.
      --
      -- The move itself is that mod's own placeTrailerAt
      -- (lib/follower/control_engine.lua:2199-2207) written out: cellX/cellY
      -- are the real position, px/py the presentation (biased per slot by
      -- `_wildsDrawBias` for its draw order), and the step state is cleared
      -- so the trailer stands on the cell rather than sliding to it. Its
      -- trail cell moves with it, because pokepcTrailCells is what the pack
      -- walks back along on the player's next step and a stale entry there
      -- would pull the follower onto the player again.
      --
      -- Every field is read defensively: this is another mod's entity table.
      local before = {}
      if type(ow.pokepcTrailers) == "table" then
        for i, npc in ipairs(ow.pokepcTrailers) do
          if type(npc) == "table" then
            before[i] = { x = npc.cellX, y = npc.cellY, facing = npc.facing }
          end
        end
      end

      pcall(syncAll, game, ow)

      pcall(function()
        local player = ow.player
        if not player or type(ow.pokepcTrailers) ~= "table" then return end
        for i, npc in ipairs(ow.pokepcTrailers) do
          local was = before[i]
          if type(npc) == "table" and was and was.x and was.y
              and npc.cellX == player.cellX and npc.cellY == player.cellY then
            npc.cellX, npc.cellY = was.x, was.y
            npc.px = was.x * 16
            npc.py = was.y * 16 + (npc._wildsDrawBias or 0)
            npc.targetX, npc.targetY = nil, nil
            npc.moving = false
            npc.progress = 0
            npc.hopStep = nil
            if was.facing then npc.facing = was.facing end
            local cells = ow.pokepcTrailCells
            if type(cells) == "table" and type(cells[i]) == "table" then
              cells[i].x, cells[i].y = was.x, was.y
            end
          end
        end
      end)
    end

    -- Whether the party is the one we opened with. Identity, not contents:
    -- the same six tables in the same order is "unchanged", and any swap,
    -- deposit or withdrawal moves at least one of them.
    local function partySnapshot()
      local out = {}
      for i, mon in ipairs(game.save.party or {}) do out[i] = mon end
      return out
    end

    local function partyChangedFrom(before)
      local now = game.save.party or {}
      if #now ~= #before then return true end
      for i = 1, #now do
        if now[i] ~= before[i] then return true end
      end
      return false
    end

    self.partyAtOpen = partySnapshot()

    function self:exit()
      -- The follower first, and outside the healing gate: BOX HEALS is off
      -- by default and this has nothing to do with it.
      if partyChangedFrom(self.partyAtOpen or {}) then refreshFollower() end

      if not healing() then return end
      local gen2 = isGen2(game)
      for _, box in ipairs(Boxes.ensure(game.save)) do
        for _, mon in ipairs(box) do
          -- guard rather than trust: a mon that arrived from a save written
          -- by an older engine may be missing the fields heal writes
          if gen2 then
            pcall(gen2Heal, game, mon)
          else
            pcall(Pokemon.heal, mon)
          end
        end
      end
    end

    -- ------- where a panel sits, in FULL SCREEN
    --
    -- Panels fill across first and then down, which is how anybody reads.
    -- Panel 0 is the top-left; `self.panel` is the one the cursor is in and
    -- `game.save.currentBox` follows it, so every action already written --
    -- pick up, put down, SORT, WALLPAPER -- keeps working on "the box the
    -- cursor is in" without knowing panels exist.
    local function panelsShown(L)
      return (L.acrossN or 1) * (L.downN or 1)
    end

    local function panelOrigin(L, p)
      local across = L.acrossN or 1
      local c, r = p % across, math.floor(p / across)
      return L.gridX + c * (L.panelW or PANEL_W),
             L.gridY + r * (L.panelH or PANEL_H)
    end

    -- which box a panel is showing: the page starts at pageBox and runs on
    local function panelBox(p)
      local n = Boxes.COUNT or 12
      return ((self.pageBox or 1) - 1 + p) % n + 1
    end

    local function cols() return self.mode == "box" and COLS or PARTY_COLS end
    local function rows() return self.mode == "box" and ROWS or PARTY_ROWS end
    local function list()
      return self.mode == "box" and boxList(game) or game.save.party
    end
    local function capacity()
      return self.mode == "box" and Boxes.CAPACITY or Party.MAX
    end

    local function index() return self.row * cols() + self.col + 1 end

    local function say(text)
      self.notice = text
      self.noticeAt = love.timer and love.timer.getTime() or 0
    end

    -- Pick up: the mon leaves its array immediately, so the slot reads
    -- empty while it rides the cursor and every count on screen stays true.
    local function grab()
      local set, i = list(), index()
      local mon = set[i]
      if not mon then return end
      -- The one rule the vanilla PC enforces that this must not lose: the
      -- party may not be emptied (bills_pc.asm refuses the last mon).
      if self.mode == "party" and #game.save.party <= 1 then
        say(Strings("THAT'S YOUR LAST ONE!"))
        return
      end
      -- MAIL (Gen 2 only): the cart's own refusal, word for word
      -- (BillsPC_CheckMon's .HasMail arm, src/core/gen2/Boxes.lua:94) -- a
      -- boxed mon has no party slot for its letter to live in, so picking
      -- one up out of the party has to refuse exactly what the vanilla PC's
      -- DEPOSIT refuses, rather than silently carrying the mon toward a box
      -- that cannot hold what it is still holding.
      if self.mode == "party" and isGen2(game) and monHoldsMail(mon) then
        say(Strings("Remove MAIL."))
        return
      end
      table.remove(set, i)
      -- The letters behind the departing mon shift up one slot, the same
      -- "Mail time!" tail RemoveMonFromPartyOrBox runs on every party
      -- removal (src/core/gen2/Mail.lua's removeSlot).
      if self.mode == "party" and isGen2(game) then
        local Mail = gen2Mail()
        if Mail then Mail.removeSlot(game.save, i) end
      end
      self.held = { mon = mon, from = self.mode }
    end

    -- The vanilla PC calls Stats.ensure on every mon it moves back into the
    -- party (src/ui/BoxMenu.lua:85): box_struct carries no stat block, so a
    -- mon decoded out of an imported .sav reaches the party with mon.stats
    -- nil and the HP bar nil-indexes it. This screen has two paths a mon
    -- can land in save.party by -- place() and stow() -- and both call this
    -- on the way in. Guarded rather than trusted, the same way BOX HEALS
    -- guards Pokemon.heal above: an old-engine mon may be missing fields
    -- Stats.calc reads, and Stats.ensure already no-ops on anything it
    -- cannot make sense of.
    local function ensureStats(mon)
      if isGen2(game) then
        pcall(gen2EnsureStats, game, mon)
        return
      end
      pcall(Stats.ensure, defOf(game, mon), mon)
    end

    -- PLACE CRY (PLAN.md "5. THE CRY ON PUT-DOWN"): every landing plays the
    -- cry of the Pokemon that landed. Sound.playCry returns nil headless,
    -- which is what makes this safe in the test suite, but it is guarded
    -- with pcall anyway -- the same rule ensureStats and BOX HEALS follow
    -- for every engine call this screen does not own. A refused placement
    -- never reaches here, because nothing landed.
    local function playLandingCry(mon)
      if not placeCryOn() then return end
      pcall(Sound.playCry, game.data, mon.species)
    end

    -- Put down. On an occupied slot the two trade places, which is what
    -- Ruby does -- the displaced one comes back onto the cursor rather than
    -- being overwritten. On an empty one the mon appends, for the
    -- compact-array reason in the header.
    local function place()
      local set, i = list(), index()
      local held = self.held.mon
      local sitting = set[i]
      if sitting then
        -- MAIL (Gen 2 only): the sitting party mon is about to be carried
        -- off exactly the way grab() carries one off, only without going
        -- through grab()'s own guard -- so the guard has to be repeated
        -- here, on the mon this swap is about to displace.
        if self.mode == "party" and isGen2(game) and monHoldsMail(sitting) then
          say(Strings("Remove MAIL."))
          return
        end
        set[i] = held
        if self.mode == "party" then
          ensureStats(held)
          -- The mon that WAS at slot i just left it (for self.held, not for
          -- any other party slot -- it is only placed once a later call
          -- resolves it), and held never carries mail (the refusals above
          -- are the whole reason). So slot i's letter, if any, departs with
          -- it: clear rather than swap, because nothing has actually taken
          -- sitting's old place yet.
          if isGen2(game) then
            local Mail = gen2Mail()
            if Mail then Mail.clear(game.save, i) end
          end
        end
        playLandingCry(held)
        self.held = { mon = sitting, from = self.mode }
        return
      end
      if #set >= capacity() then
        say(self.mode == "box" and Strings("THE BOX IS FULL!")
                                or Strings("YOUR PARTY IS FULL!"))
        return
      end
      if self.mode == "party" and isGen2(game) then
        gen2InsertPartySlot(game, #set + 1)
      end
      set[#set + 1] = held
      if self.mode == "party" then ensureStats(held) end
      playLandingCry(held)
      self.held = nil
    end

    -- Put the carried mon back somewhere legal, for B and for anything else
    -- that has to end the carry. It prefers where the mon came from, falls
    -- back to the other pane, and REFUSES rather than overflowing: a swap
    -- across the two panes can leave the cursor holding a box mon while the
    -- box is at twenty, and appending there would push it to twenty-one --
    -- a box the vanilla PC cannot show and the save format does not allow.
    local function stow()
      local held = self.held.mon
      local box, party = boxList(game), game.save.party
      local a, aCap, b, bCap
      if self.held.from == "box" then
        a, aCap, b, bCap = box, Boxes.CAPACITY, party, Party.MAX
      else
        a, aCap, b, bCap = party, Party.MAX, box, Boxes.CAPACITY
      end
      if #a < aCap then
        if a == party and isGen2(game) then gen2InsertPartySlot(game, #a + 1) end
        a[#a + 1] = held
        if a == party then ensureStats(held) end
        playLandingCry(held)
        self.held = nil
        return true
      end
      if #b < bCap then
        if b == party and isGen2(game) then gen2InsertPartySlot(game, #b + 1) end
        b[#b + 1] = held
        if b == party then ensureStats(held) end
        playLandingCry(held)
        self.held = nil
        return true
      end
      say(Strings("NO ROOM ANYWHERE!"))
      return false
    end

    -- ------- bringing a box under the cursor
    --
    -- FIND and JUMP TO BOX set currentBox and expect the screen to be
    -- looking at it. In one-box layouts that is automatic; in FULL SCREEN
    -- it is not -- the box may not be on the page at all, and setting the
    -- number alone left the cursor sitting in whatever panel it was in,
    -- pointing at a different box entirely. This is the one place that
    -- knows how to make a box VISIBLE, so both callers go through it.
    local function focusBox(boxNum)
      game.save.currentBox = boxNum
      local L = layout(game)
      if not L.full then return end
      local shown = panelsShown(L)
      -- put it on the page: the page starts at the box that puts this one
      -- in the first panel, unless it is already on screen
      local page = self.pageBox or 1
      local at = (boxNum - page) % (Boxes.COUNT or 12)
      if at >= shown then
        self.pageBox = boxNum
        at = 0
      end
      self.panel = at
    end

    -- exposed for the suite: "a box the player asked for is on screen and
    -- under the cursor" is the invariant FIND and JUMP TO BOX depend on,
    -- and it is not visible from outside otherwise
    self.focusBox = function(n) return focusBox(n) end
    self.panelBox = function(p) return panelBox(p) end

    -- ------- MOVE MANY: the move itself
    --
    -- Everything ticked leaves its box and lands in the one being looked
    -- at, in the order it was in. It refuses rather than half-moves: if
    -- there is not room for all of them the box is left exactly as it was,
    -- because a partial move of a selection you cannot see the end of is
    -- worse than no move at all.
    local function moveTicked()
      if not self.manyBox then return end
      local from = game.save.boxes[self.manyBox] or {}
      local picked = {}
      for i in pairs(self.many) do picked[#picked + 1] = i end
      table.sort(picked)
      if #picked == 0 then
        say(Strings("TICK SOME FIRST."))
        return
      end
      local target = game.save.currentBox
      if target == self.manyBox then
        say(Strings("PICK ANOTHER BOX."))
        return
      end
      local into = game.save.boxes[target] or {}
      if #into + #picked > Boxes.CAPACITY then
        say(Strings("BOX %d HAS NO ROOM.", target))
        return
      end
      -- take them from the end backwards, so the earlier indices stay valid
      local moving = {}
      for k = #picked, 1, -1 do
        local mon = table.remove(from, picked[k])
        if mon then table.insert(moving, 1, mon) end
      end
      for _, mon in ipairs(moving) do into[#into + 1] = mon end
      game.save.boxes[target] = into
      self.many = {}
      self.manyBox = target
      say(Strings("MOVED %d TO BOX %d.", #moving, target))
    end

    local function changeBox(step)
      if self.mode ~= "box" then return end
      local n = Boxes.COUNT
      focusBox(((game.save.currentBox - 1 + step) % n) + 1)
    end

    -- ------- WHAT A DRAG MEANS, PER LAYOUT
    --
    -- Not the same verb on the two surfaces, and the first cut used the
    -- wrong one on the bigger of them.
    --
    -- On the ordinary screen one box fills the grid, so a drag is "the box
    -- before / the box after" and goes through `changeBox` -- the wrap and
    -- the party guard already live in there.
    --
    -- In FULL SCREEN several boxes are on screen at once, stacked down the
    -- glass on a phone. "The next box" is not a scroll there, it is a
    -- cursor move; what scrolls is `pageBox`, the box the first panel
    -- stands for, and it moves by a ROW of panels at a time -- which is
    -- exactly what movePanel does when the cursor walks off the edge
    -- (see it advance pageBox by `across` there). Dragging drove
    -- `changeBox` instead, so the cursor hopped between the panels already
    -- on screen and nothing ever scrolled.
    --
    -- The axis follows the layout rather than a fixed guess: panels are
    -- laid out `acrossN` by `downN`, so a column of them scrolls
    -- vertically and a row of them horizontally. The hook hands over the
    -- axis the finger actually travelled on and this decides whether that
    -- axis means anything here.
    self.touchScroll = function(dir, axis)
      if self.mode ~= "box" then return false end
      local L = layout(game)
      if not L.full then
        -- one box on screen: either axis reads as "the next one"
        local was = game.save.currentBox
        changeBox(dir)
        return game.save.currentBox ~= was
      end
      local across, down = L.acrossN or 1, L.downN or 1
      -- the axis that has more than one panel on it is the one that scrolls
      local wants = (down > 1 and "y") or (across > 1 and "x") or "y"
      if axis ~= wants then return false end
      local was = self.pageBox or 1
      local step = (wants == "y") and across or 1
      self.pageBox = ((was - 1 + dir * step) % Boxes.COUNT) + 1
      game.save.currentBox = panelBox(self.panel or 0)
      return self.pageBox ~= was
    end

    -- Walking off the left or right edge of a box steps to the next one, the
    -- way Ruby's L/R do -- a Game Boy has no shoulder buttons to spare, and
    -- this frees START to be a way out that always works. In the party pane
    -- there is nowhere to step to, so it wraps or clamps as before.
    -- FULL SCREEN: walking off a panel steps to the NEXT PANEL rather than
    -- to the next box, because the next box is already on screen -- and
    -- when there is no panel that way, the page of boxes scrolls by one so
    -- the cursor keeps going in the direction it was pushed.
    local function movePanel(dc, dr)
      local L = layout(game)
      local across, down = L.acrossN or 1, L.downN or 1
      local p = self.panel or 0
      local pc, pr = p % across, math.floor(p / across)
      if dc ~= 0 then
        pc = pc + dc
        if pc < 0 then
          self.pageBox = ((self.pageBox or 1) - 2) % (Boxes.COUNT) + 1
          pc = 0
        elseif pc >= across then
          self.pageBox = (self.pageBox or 1) % (Boxes.COUNT) + 1
          pc = across - 1
        end
      end
      if dr ~= 0 then
        pr = pr + dr
        -- a row of panels is `across` boxes, so scrolling by a row moves
        -- the page by that many
        if pr < 0 then
          self.pageBox = ((self.pageBox or 1) - 1 - across) % (Boxes.COUNT) + 1
          pr = 0
        elseif pr >= down then
          self.pageBox = ((self.pageBox or 1) - 1 + across) % (Boxes.COUNT) + 1
          pr = down - 1
        end
      end
      self.panel = pr * across + pc
      game.save.currentBox = panelBox(self.panel)
    end

    local function move(dc, dr)
      local L = layout(game)
      local c, r = self.col + dc, self.row + dr
      if L.full and self.mode == "box" then
        if dc ~= 0 and (c < 0 or c >= cols()) then
          movePanel(dc, 0)
          self.col = c < 0 and (cols() - 1) or 0
          return
        end
        if dr ~= 0 and (r < 0 or r >= rows()) then
          if dr < 0 then
            -- up out of the top row is this panel's own name, not the panel
            -- above: the name is a row of the panel, and skipping it would
            -- put the BOX MENU out of reach for every box but one
            self.header = true
            return
          end
          movePanel(0, dr)
          self.row = 0
          return
        end
        self.col = math.max(0, math.min(cols() - 1, c))
        self.row = math.max(0, math.min(rows() - 1, r))
        return
      end
      if self.mode == "box" and dc ~= 0 and (c < 0 or c >= cols()) then
        changeBox(dc)
        self.col = c < 0 and (cols() - 1) or 0
        return
      end
      if mod.options:get("wrap") then
        c = (c + cols()) % cols()
        r = (r + rows()) % rows()
      else
        c = math.max(0, math.min(cols() - 1, c))
        r = math.max(0, math.min(rows() - 1, r))
      end
      self.col, self.row = c, r
    end

    local function switchMode()
      self.mode = self.mode == "box" and "party" or "box"
      self.col, self.row = 0, 0
      -- the party pane has no header, so crossing to it always drops back
      -- into the grid
      self.header = false
    end

    -- The summary screen the rest of the game uses. It recalculates a box
    -- mon's stat block on the way in (status_screen.asm does the same,
    -- because box_struct carries none), so handing it one straight out of
    -- save.boxes is the supported path -- Bill's PC STATS entry does
    -- exactly this.
    --
    -- The two screens are NOT closed the same way, which is the whole of
    -- issue #5. Gen 1's SummaryMenu pops itself (src/ui/SummaryMenu.lua:65:
    -- A or B off page two calls game.stack:pop()), so handing it the mon and
    -- walking away is complete. Gold's does not: every exit path in
    -- src/ui/gen2/SummaryMenu.lua ends at self:close(), and close() is
    -- `if self.onClose then self.onClose() end` (:664-666) -- with no
    -- callback the screen answers B by doing nothing at all and stays on the
    -- stack forever, which is the soft lock as reported. Gold's own PC passes
    -- one (src/ui/gen2/BoxMenu.lua:309-313) and so does its party menu; this
    -- screen was the only caller that did not.
    local function showStats()
      local mon = self.held and self.held.mon or list()[index()]
      if not mon then return end
      if isGen2(game) then
        -- the same guard the vanilla Gold PC uses one line above its own
        -- push: an engine build without the screen registered leaves STATS
        -- doing nothing, rather than throwing inside a menu
        if not pcall(Screens.get, game, SCREEN_SUMMARY_GEN2) then return end
        Screens.push(game, SCREEN_SUMMARY_GEN2, {
          mon = mon,
          onClose = function() game.stack:pop() end,
        })
      else
        Screens.push(game, SCREEN_SUMMARY_GEN1, mon)
      end
    end

    -- B, wherever it is pressed: back, and only back, exactly the rule
    -- above already follows -- carrying one it goes back to a shelf first,
    -- otherwise it leaves. The header shares this rather than repeating it.
    -- MARK MODE adds one more stop before the exit (PLAN.md "3. MARKS"): B
    -- leaves the mode first, and only the next B leaves the screen.
    local function back()
      if self.held then
        if stow() then say(Strings("PUT IT BACK.")) end
      elseif self.markMode then
        self.markMode = false
      else
        game.stack:pop()
      end
    end

    -- ------- SORT + UNDO
    --
    -- Every key falls back to the mon's CURRENT index, so two mons that tie
    -- sort into the same order they started in -- a stable sort -- and the
    -- array stays exactly as compact as it was: this only ever reorders in
    -- place, never removes or appends.
    local function sortKey(mon, key)
      if key == "dex" then
        local def = defOf(game, mon)
        return def and def.dex
      elseif key == "level" then
        return mon.level or 0
      elseif key == "name" then
        return nameOf(game, mon)
      elseif key == "type" then
        local def = defOf(game, mon)
        return def and def.types and def.types[1]
      end
    end

    -- A species this screen no longer has a definition for (a save left
    -- over from a species-adding mod that's since been turned off) sorts to
    -- the end rather than erroring the comparison.
    local function sortBox(key)
      local set = boxList(game)
      local n = #set
      local order = {}
      for i = 1, n do order[i] = i end
      table.sort(order, function(ia, ib)
        local ma, mb = set[ia], set[ib]
        local ka, kb = sortKey(ma, key), sortKey(mb, key)
        if ka == kb then
          -- BY TYPE's secondary key is dex, THEN the current index
          if key == "type" then
            local da, db = sortKey(ma, "dex"), sortKey(mb, "dex")
            if da ~= db then
              if da == nil then return false end
              if db == nil then return true end
              return da < db
            end
          end
          return ia < ib
        end
        if ka == nil then return false end
        if kb == nil then return true end
        -- BY LEVEL is the one descending key: the strongest first is what
        -- anyone sorting a box actually wants
        if key == "level" then return ka > kb end
        return ka < kb
      end)
      local sorted = {}
      for i, oldIndex in ipairs(order) do sorted[i] = set[oldIndex] end
      for i = 1, n do set[i] = sorted[i] end
    end

    -- true only if `a` and `b` hold the same mons, by table identity, in
    -- any order -- so undo can never resurrect one that was moved away
    -- while sorted, or drop one that arrived since
    local function samePokemon(a, b)
      if #a ~= #b then return false end
      local counts = {}
      for _, mon in ipairs(a) do counts[mon] = (counts[mon] or 0) + 1 end
      for _, mon in ipairs(b) do
        if not counts[mon] or counts[mon] == 0 then return false end
        counts[mon] = counts[mon] - 1
      end
      return true
    end

    local function snapshotForUndo()
      local set = boxList(game)
      local copy = {}
      for i, mon in ipairs(set) do copy[i] = mon end
      self.sortUndo = { boxNum = game.save.currentBox, mons = copy }
    end

    -- Refuses -- leaving the box exactly as it was -- unless the snapshot
    -- still describes what is in the box now.
    local function undoSort()
      local snap = self.sortUndo
      if not snap or snap.boxNum ~= game.save.currentBox then return false end
      local set = boxList(game)
      if not samePokemon(snap.mons, set) then return false end
      for i, mon in ipairs(snap.mons) do set[i] = mon end
      return true
    end

    -- ------- FIND and FIND NEXT
    --
    -- Every box, walking forward from the cursor and wrapping back around to
    -- where it started (PLAN.md "1. FIND, and JUMP TO BOX"). The party is
    -- deliberately not searched -- it is six visible slots on the same
    -- screen already.
    --
    -- A box is exactly COLS*ROWS = Boxes.CAPACITY cells, so the cursor's own
    -- (col, row) already IS a 1..20 index into that box's compact array --
    -- the same index() the grid uses. That lets the search treat "every
    -- box" as one flat ring of 12*20 slots addressed by (box, index) without
    -- inventing a second numbering.
    local function slotAt(g)
      local boxNum = math.floor((g - 1) / Boxes.CAPACITY) + 1
      local idx = ((g - 1) % Boxes.CAPACITY) + 1
      return boxNum, idx
    end
    local function slotOf(boxNum, idx) return (boxNum - 1) * Boxes.CAPACITY + idx end

    local function matchesQuery(mon, query)
      if query.kind == "species" then
        local q = query.value:lower()
        local def = defOf(game, mon)
        local nick = (mon.nickname or ""):lower()
        local name = (def and def.name or ""):lower()
        local id = tostring(mon.species or ""):lower()
        return nick:find(q, 1, true) ~= nil
          or name:find(q, 1, true) ~= nil
          or id:find(q, 1, true) ~= nil
      elseif query.kind == "type" then
        local def = defOf(game, mon)
        if not (def and def.types) then return false end
        for _, t in ipairs(def.types) do
          if t == query.value then return true end
        end
        return false
      elseif query.kind == "mark" then
        return getMark(mon, query.value)
      end
      return false
    end

    -- Searches from the cell right after the cursor, all the way around the
    -- ring and back to the cursor's own cell (the last one checked) -- so a
    -- lone match sitting under the cursor is still found on the next FIND
    -- NEXT. A hit moves currentBox/col/row and reports the name; a miss
    -- reports that and moves nothing.
    local function findNext(query)
      local boxes = Boxes.ensure(game.save)
      local total = Boxes.COUNT * Boxes.CAPACITY
      local start = slotOf(game.save.currentBox, index())
      -- always lands back on the grid, hit or miss, the same as every other
      -- box-menu action
      self.header = false
      for step = 1, total do
        local g = ((start - 1 + step) % total) + 1
        local boxNum, idx = slotAt(g)
        local mon = boxes[boxNum][idx]
        if mon and matchesQuery(mon, query) then
          focusBox(boxNum)
          self.col = (idx - 1) % COLS
          self.row = math.floor((idx - 1) / COLS)
          self.header = false
          say(Strings("FOUND %s!", nameOf(game, mon)))
          return true
        end
      end
      say(Strings("NOT FOUND."))
      return false
    end

    -- Runs the search, remembers the query for FIND NEXT, and closes every
    -- menu FIND opened on the way -- landing back on the grid whether the
    -- search hit or missed.
    local function runFind(query, menus)
      self.findQuery = query
      findNext(query)
      for _, menu in ipairs(menus) do menu:close() end
    end

    -- game.data.pokemon, deduped and sorted -- so a species-adding mod's
    -- types show up here without being named in this file.
    local function allTypes()
      local seen, out = {}, {}
      for _, def in pairs(game.data.pokemon or {}) do
        if def.types then
          for _, t in ipairs(def.types) do
            if not seen[t] then
              seen[t] = true
              out[#out + 1] = t
            end
          end
        end
      end
      table.sort(out)
      return out
    end

    local function openFindType(findMenu, boxMenu)
      local items = {}
      for _, t in ipairs(allTypes()) do
        table.insert(items, { label = t, value = t })
      end
      local sub
      sub = mod.ui.ListMenu.new(game, Strings("TYPE"), items, {
        kind = "gen3_box_find_type",
        onChoose = function(item)
          runFind({ kind = "type", value = item.value }, { sub, findMenu, boxMenu })
        end,
      })
      game.stack:push(sub)
    end

    -- The four symbols by word (the font has no glyph for the real marks).
    local function openFindMark(findMenu, boxMenu)
      local items = {}
      for _, name in ipairs(MARK_ORDER) do
        table.insert(items, { label = Strings(name), value = name })
      end
      local sub
      sub = mod.ui.ListMenu.new(game, Strings("MARK"), items, {
        kind = "gen3_box_find_mark",
        onChoose = function(item)
          runFind({ kind = "mark", value = item.value }, { sub, findMenu, boxMenu })
        end,
      })
      game.stack:push(sub)
    end

    -- The naming screen (src/ui/NamingScreen.lua): a substring match against
    -- the nickname, the species name and the raw species id, so CHAR finds
    -- CHARMANDER and a Pokemon nicknamed CHARLIE alike. An empty confirm
    -- (NamingScreen's own "declined" contract) starts no search.
    local function openFindSpecies(findMenu, boxMenu)
      game.stack:push(mod.ui.NamingScreen.new(game, {
        title = Strings("FIND SPECIES"),
        maxLen = 10,
        default = "",
        onDone = function(name)
          if name == "" then
            findMenu:close()
            boxMenu:close()
            return
          end
          runFind({ kind = "species", value = name }, { findMenu, boxMenu })
        end,
      }))
    end

    local function openFindMenu(boxMenu)
      local items = {
        { label = Strings("SPECIES"), value = "species" },
        { label = Strings("TYPE"), value = "type" },
        { label = Strings("MARK"), value = "mark" },
      }
      local sub
      sub = mod.ui.ListMenu.new(game, Strings("FIND"), items, {
        kind = "gen3_box_find",
        onChoose = function(item)
          if item.value == "species" then
            openFindSpecies(sub, boxMenu)
          elseif item.value == "type" then
            openFindType(sub, boxMenu)
          elseif item.value == "mark" then
            openFindMark(sub, boxMenu)
          end
        end,
      })
      game.stack:push(sub)
    end

    -- ------- MARK MODE and the marking window
    --
    -- The window is tile-aligned and scales with the layout, the same
    -- doubling as everything else BIG touches: the CLASSIC rect times
    -- cell/28 lands back on CLASSIC's own numbers and on BIG's at cell/28==2.
    local function markWindowRect()
      local L = layout(game)
      local k = L.cell / 28
      return 8 * k, 48 * k, 144 * k, 48 * k
    end

    local function openMarkWindowOnCursor()
      local mon = list()[index()]
      if not mon then return end
      self.markWindow = { mon = mon, cursor = 1 }
    end

    -- UP and DOWN as well as LEFT and RIGHT.
    --
    -- PLAN.md specified this window as a ROW of four symbols and gave it
    -- LEFT/RIGHT, but drawMarkWindow draws the four names STACKED, one per
    -- line. The drawing moved and the keys did not, so the obvious press --
    -- DOWN, on a vertical list -- did nothing at all, and the window read
    -- as a dead panel. Both axes work now: the list is vertical, so the
    -- vertical keys are the honest ones, and the horizontal pair is kept
    -- because a player who learned them in 1.6.0 should not lose them.
    local function updateMarkWindow()
      local input = game.input
      local win = self.markWindow
      if input:wasPressed("left") or input:wasPressed("up") then
        win.cursor = win.cursor > 1 and win.cursor - 1 or #MARK_ORDER
      elseif input:wasPressed("right") or input:wasPressed("down") then
        win.cursor = win.cursor < #MARK_ORDER and win.cursor + 1 or 1
      elseif input:wasPressed("a") then
        local name = MARK_ORDER[win.cursor]
        setMark(win.mon, name, not getMark(win.mon, name))
      elseif input:wasPressed("b") then
        self.markWindow = nil
      end
    end

    -- ------- the BOX MENU
    --
    -- A mod.ui.ListMenu, titled with the box's name (src/ui/ListMenu.lua).
    -- Rows are appended in the order PLAN.md lists them so a later wave
    -- inserts its own without reshuffling what is already here: NAME BOX and
    -- WALLPAPER go between JUMP TO BOX and MARK MODE.
    local function boxMenuItems()
      local items = {}
      table.insert(items, { label = Strings("FIND"), value = "find" })
      if self.findQuery then
        table.insert(items, { label = Strings("FIND NEXT"), value = "findnext" })
      end
      table.insert(items, { label = Strings("SORT"), value = "sort" })
      table.insert(items, { label = Strings("JUMP TO BOX"), value = "jump" })
      table.insert(items, { label = Strings("NAME BOX"), value = "namebox" })
      table.insert(items, { label = Strings("WALLPAPER"), value = "wallpaper" })
      table.insert(items, { label = Strings("MARK MODE"), value = "markmode" })
      table.insert(items, { label = Strings("MOVE MANY"), value = "movemany" })
      -- so the news can be read on purpose, not only on the one boot after
      -- an update
      table.insert(items, { label = Strings("WHAT'S NEW"), value = "news" })
      table.insert(items, { label = Strings("CANCEL"), value = "cancel" })
      return items
    end

    -- BY DEX / BY LEVEL / BY NAME / BY TYPE / UNDO. A choice acts, then
    -- closes itself and its parent in turn (sub:close(), then parent:
    -- close()), so it lands back on the grid; B leaves this list for the
    -- box menu, ListMenu's own doing.
    local function openSortMenu(parent)
      local items = {
        { label = Strings("BY DEX"), value = "dex" },
        { label = Strings("BY LEVEL"), value = "level" },
        { label = Strings("BY NAME"), value = "name" },
        { label = Strings("BY TYPE"), value = "type" },
        { label = Strings("UNDO"), value = "undo" },
      }
      local sub
      sub = mod.ui.ListMenu.new(game, Strings("SORT"), items, {
        kind = "gen3_box_sort",
        onChoose = function(item)
          if item.value == "undo" then
            if undoSort() then
              self.header = false
              say(Strings("UNDONE."))
              sub:close()
              parent:close()
            else
              -- refuses, changing nothing, and stays open -- exactly the
              -- shape the vanilla PC uses for "the party is full" (#570)
              sub.footer = Strings("CAN'T UNDO NOW.")
            end
            return
          end
          snapshotForUndo()
          sortBox(item.value)
          self.header = false
          say(Strings("SORTED."))
          sub:close()
          parent:close()
        end,
      })
      game.stack:push(sub)
    end

    -- The twelve boxes, each with its name and n/20, the same shape
    -- BoxMenu.changeBox shows (src/ui/BoxMenu.lua) -- minus its save
    -- prompt, because this screen writes no save.
    local function openJumpMenu(parent)
      local boxes = Boxes.ensure(game.save)
      local items = {}
      for i = 1, Boxes.COUNT do
        local mark = i == game.save.currentBox and "*" or ""
        table.insert(items, {
          label = mark .. boxName(i),
          right = ("%d/%d"):format(#boxes[i], Boxes.CAPACITY),
          value = i,
        })
      end
      local sub
      sub = mod.ui.ListMenu.new(game, Strings("JUMP TO BOX"), items, {
        kind = "gen3_box_jump",
        onChoose = function(item)
          focusBox(item.value)
          self.header = false
          sub:close()
          parent:close()
        end,
      })
      game.stack:push(sub)
    end

    -- NAME BOX: the engine's own naming screen, 8 glyphs, defaulting to the
    -- box's current name (PLAN.md "4. BOX NAMES and WALLPAPERS"). "default"
    -- is NamingScreen's own declined-confirm fallback, not a glyph pre-fill
    -- -- self.glyphs always starts empty (src/ui/NamingScreen.lua:73), so
    -- typing nothing and confirming hands back exactly what `default` was
    -- given, the same contract a declined nickname keeps the old one under.
    -- So a confirm with nothing typed is a no-op here: it reconfirms
    -- whatever the box was already called, custom name included, which is
    -- an honest engine-shaped reading of the plan's "an empty confirm
    -- stores nothing" -- on a box with no custom name that default already
    -- IS "BOX n", so nothing changes there either. Typing back the literal
    -- "BOX n" is the one input that always clears a custom name, because it
    -- is compared against the canonical string below rather than against
    -- an impossible-to-reach raw "".
    local function openNameBoxScreen(boxMenu)
      local n = game.save.currentBox
      game.stack:push(mod.ui.NamingScreen.new(game, {
        title = Strings("BOX NAME?"),
        maxLen = 8,
        default = boxName(n),
        onDone = function(name)
          local canonical = Strings("BOX %d", n)
          if name == "" or name == canonical then
            local names = mod.save:get("boxNames")
            if names then
              names[n] = nil
              names[tostring(n)] = nil
            end
          else
            local names = mod.save:get("boxNames")
            if not names then
              names = {}
              mod.save:set("boxNames", names)
            end
            names[n] = name
            names[tostring(n)] = nil
          end
          self.header = false
          boxMenu:close()
        end,
      }))
    end

    -- WALLPAPER: not a ListMenu but a chooser this screen draws ITSELF, and
    -- that is the whole point. A pushed menu is a state of its own with the
    -- box frozen behind it; this one lives inside the screen, so the
    -- wallpaper under the cursor is drawn as the real background while you
    -- scroll -- the preview IS the box.
    --
    -- Each row is a place and a hand: FOREST < ANSIMUZ >. Up and down change
    -- the place, left and right change who drew it, and every box keeps its
    -- own pair -- two boxes can both be FOREST in two different hands.
    local function openWallpaperMenu(parent)
      local n = game.save.currentBox
      local current = paperEntry(n)
      local cat = 1
      for i, w in ipairs(WALLPAPERS) do
        if w.id == current.id then cat = i end
      end
      -- the artist remembered per category, so moving up and down does not
      -- lose the hand you had already picked for the place you left
      local art = {}
      for _, w in ipairs(WALLPAPERS) do art[w.id] = 1 end
      art[current.id] = current.art
      self.paperPick = { cat = cat, art = art[WALLPAPERS[cat].id],
                         artBy = art, box = n, id = WALLPAPERS[cat].id }
      self.header = false
      if parent then parent:close() end
    end

    local function openBoxMenu()
      local menu
      menu = mod.ui.ListMenu.new(game, boxName(game.save.currentBox),
        boxMenuItems(), {
        kind = "gen3_box_menu",
        onChoose = function(item)
          if item.value == "find" then
            openFindMenu(menu)
          elseif item.value == "findnext" then
            if self.findQuery then findNext(self.findQuery) end
            self.header = false
            menu:close()
          elseif item.value == "sort" then
            openSortMenu(menu)
          elseif item.value == "jump" then
            openJumpMenu(menu)
          elseif item.value == "namebox" then
            openNameBoxScreen(menu)
          elseif item.value == "wallpaper" then
            openWallpaperMenu(menu)
          elseif item.value == "markmode" then
            self.markMode = not self.markMode
            self.header = false
            menu:close()
          elseif item.value == "movemany" then
            -- ------- MOVE MANY
            --
            -- Pokemon Box on the GameCube lets you take a handful at once,
            -- and a storage screen that moves them one at a time is a
            -- storage screen you use twice and then avoid. A ticks and
            -- unticks, START moves everything ticked into the box you are
            -- looking at, B leaves.
            --
            -- The ticks belong to the box they were made in: walking to
            -- another box and ticking there would otherwise build a
            -- selection spanning boxes whose slot numbers mean different
            -- things.
            self.moveMany = not self.moveMany
            self.many = {}
            self.manyBox = self.moveMany and game.save.currentBox or nil
            self.header = false
            say(self.moveMany
              and Strings("A:TICK START:MOVE")
              or Strings("MOVE MANY OFF."))
            menu:close()
          elseif item.value == "news" then
            self.openNews()
            self.header = false
            menu:close()
          elseif item.value == "cancel" then
            menu:close()
          end
        end,
      })
      game.stack:push(menu)
    end

    -- The header row (PLAN.md "the control scheme"): UP out of the top row
    -- of the grid, in box mode only, lands here rather than on the grid's
    -- own wrap. Nothing is "selected" on it, so START -- the summary key
    -- everywhere else -- opens nothing.
    local function updateHeader()
      local input = game.input
      local L = layout(game)
      if input:wasPressed("down") then
        self.header = false
      elseif input:wasPressed("left") then
        -- in full screen the name row moves the way the grid does: to the
        -- panel beside it, and off the last one the page scrolls. Anywhere
        -- else there is only one box on screen, so it changes box.
        if L.full then movePanel(-1, 0) else changeBox(-1) end
      elseif input:wasPressed("right") then
        if L.full then movePanel(1, 0) else changeBox(1) end
      elseif input:wasPressed("up") then
        if L.full then
          -- up from a name goes to the BOTTOM row of the panel above, so
          -- the cursor walks the screen continuously instead of stopping
          movePanel(0, -1)
          self.header = false
          self.row = rows() - 1
        elseif mod.options:get("wrap") then
          -- the deliberate change PLAN.md calls out: wrap no longer takes
          -- UP from the top row straight to the bottom -- it stops here
          -- first, and UP again is what wraps
          self.header = false
          self.row = rows() - 1
        end
      elseif input:wasPressed("a") then
        openBoxMenu()
      elseif input:wasPressed("start") then
        -- the header is the one place START has no summary to show, so it
        -- costs no binding to make it FIND NEXT (PLAN.md "1. FIND, and JUMP
        -- TO BOX") when a search is active
        if self.findQuery then findNext(self.findQuery) end
      elseif input:wasPressed("select") then
        switchMode()
      elseif input:wasPressed("b") then
        back()
      end
    end

    function self:update()
      -- The wallpaper clock. Ticked here rather than in draw() because draw
      -- can run more than once for a logic frame (and not at all when the
      -- screen is covered), and a pattern that drifted at the frame rate
      -- would run at a different speed on a different machine. One tick per
      -- logic step is the same cadence the rest of this screen moves at.
      --
      -- Before the early returns below: the box behind an open menu keeps
      -- breathing rather than freezing the moment you press A.
      self.paperTick = (self.paperTick or 0) + 1

      -- WHAT'S NEW owns every key while it is open, like the chooser below:
      -- a popup you can walk out from behind is a popup nobody reads.
      if self.news then
        self.updateNews()
        return
      end

      -- the wallpaper chooser owns the keys while it is open, and nothing
      -- else on this screen moves: the cursor in the grid must not wander
      -- behind a menu the player is reading.
      if self.paperPick then
        local input = game.input
        local pick = self.paperPick
        local function styles() return artFor(WALLPAPERS[pick.cat].id) end
        if input:wasPressed("up") or input:wasPressed("down") then
          local step = input:wasPressed("up") and -1 or 1
          pick.moved = true
          pick.cat = ((pick.cat - 1 + step) % #WALLPAPERS) + 1
          pick.id = WALLPAPERS[pick.cat].id
          pick.art = pick.artBy[pick.id] or 1
        elseif input:wasPressed("left") or input:wasPressed("right") then
          local step = input:wasPressed("left") and -1 or 1
          local list = styles()
          pick.art = ((pick.art - 1 + step) % #list) + 1
          pick.artBy[pick.id] = pick.art
        elseif input:wasPressed("select") then
          -- SELECT marks what you are looking at as THE favourite: not for
          -- this box, for the mod. Any box set to FAVOURITE follows it from
          -- now on, which is what makes that category worth having.
          if pick.id == "FAVE" then
            say(Strings("PICK A REAL ONE."))
          else
            local added = toggleFave(pick.id, pick.art)
            say(Strings(added and "ADDED TO FAVOURITES." or "REMOVED."))
          end
        elseif input:wasPressed("start") then
          pick.moved = true
          -- RANDOM moved here when SELECT took on the favourite. A place and
          -- a hand at once: drawing only one of the two is a half-measure.
          pick.cat = math.random(#WALLPAPERS)
          pick.id = WALLPAPERS[pick.cat].id
          local list = artFor(pick.id)
          pick.art = math.random(#list)
          pick.artBy[pick.id] = pick.art
        elseif input:wasPressed("a") then
          setPaperEntry(pick.box, pick.id, pick.art)
          self.paperPick = nil
          say(Strings("WALLPAPER SET."))
        elseif input:wasPressed("b") then
          self.paperPick = nil
        end
        return
      end

      if self.markWindow then
        updateMarkWindow()
        return
      end
      if self.mode == "box" and self.header then
        updateHeader()
        return
      end
      local input = game.input
      if input:wasPressed("up") then
        -- UP from the top row lands on the box's NAME, and in full screen
        -- that is this panel's name -- every panel has one, so every box on
        -- screen has its own way into the BOX MENU. A press there opens the
        -- menu for the box the cursor is in, which currentBox already
        -- follows.
        if self.mode == "box" and self.row == 0 then
          self.header = true
        else
          move(0, -1)
        end
      elseif input:wasPressed("down") then move(0, 1)
      elseif input:wasPressed("left") then move(-1, 0)
      elseif input:wasPressed("right") then move(1, 0)
      elseif input:wasPressed("a") then
        if self.moveMany and self.mode == "box" then
          -- A ticks and unticks. An empty slot has nothing to tick, and
          -- saying so beats a press that appears to do nothing.
          local set, i = list(), index()
          if game.save.currentBox ~= self.manyBox then
            say(Strings("TICKS BELONG TO BOX %d.", self.manyBox or 0))
          elseif not set[i] then
            say(Strings("NOTHING THERE."))
          else
            self.many[i] = (not self.many[i]) or nil
            local n = 0
            for _ in pairs(self.many) do n = n + 1 end
            say(Strings("%d TICKED. START:MOVE", n))
          end
        elseif self.held then
          place()
        elseif self.markMode then
          openMarkWindowOnCursor()
        else
          grab()
        end
      elseif input:wasPressed("select") then switchMode()
      elseif input:wasPressed("start") then
        if self.moveMany and self.mode == "box" then
          moveTicked()
        else
          -- START is the summary. It can be, because B below always means
          -- back: there is no cell where the way out disappears, which is
          -- what forced the earlier arrangement into putting STATS on B.
          showStats()
        end
      elseif input:wasPressed("b") then
        back()
      end
    end

    -- ------- drawing

    local function cellRect(i0, mode, panel)
      local L = layout(game)
      mode = mode or self.mode
      local n = mode == "box" and COLS or PARTY_COLS
      local c, r = i0 % n, math.floor(i0 / n)
      if mode ~= "box" then
        return L.partyX + c * L.cell, L.partyY + r * L.cell
      end
      if L.full then
        local ox, oy = panelOrigin(L, panel or self.panel or 0)
        return ox + c * L.cell, oy + 14 + r * L.cell
      end
      return L.gridX + c * L.cell, L.gridY + r * L.cell
    end
    self.cellRect = cellRect

    -- ------- A FINGER, TURNED BACK INTO A CELL
    --
    -- cellRect read backwards, and deliberately the only place a point is
    -- converted: the drawing and the touch cannot end up disagreeing about
    -- where a cell is when they are the same arithmetic either way.
    --
    -- Full screen answers the PANEL too, because there the same cell index
    -- exists once per box on screen and "which slot" is only half the
    -- question. `gameX/gameY` arrive already local to the game viewport, so
    -- nothing here has to know about the window scale or the surround.
    local function hitAt(px, py)
      local L = layout(game)
      if not L or not L.cell or L.cell <= 0 then return nil end
      if self.mode == "box" and L.full then
        for p = 0, panelsShown(L) - 1 do
          local ox, oy = panelOrigin(L, p)
          local c = math.floor((px - ox) / L.cell)
          local r = math.floor((py - (oy + 14)) / L.cell)
          if c >= 0 and r >= 0 and c < COLS and r < ROWS then
            return r * COLS + c, p
          end
        end
        return nil
      end
      local n = self.mode == "box" and COLS or PARTY_COLS
      local rows = self.mode == "box" and ROWS or PARTY_ROWS
      local bx = self.mode == "box" and L.gridX or L.partyX
      local by = self.mode == "box" and L.gridY or L.partyY
      local c = math.floor((px - bx) / L.cell)
      local r = math.floor((py - by) / L.cell)
      if c < 0 or r < 0 or c >= n or r >= rows then return nil end
      return r * n + c, nil
    end
    self.hitAt = hitAt

    -- ------- what a finger is allowed to do
    --
    -- Through the same code the buttons use: the cursor is `self.col` and
    -- `self.row`, and acting is the same `a` branch. Both answer true when
    -- they did something, so the hook knows whether to consume the event.
    self.touchTap = function(i0, panel)
      local n = self.mode == "box" and COLS or PARTY_COLS
      local c, r = i0 % n, math.floor(i0 / n)
      local samePanel = (panel == nil) or (panel == (self.panel or 0))
      if not samePanel or c ~= self.col or r ~= self.row then
        if panel ~= nil and panel ~= (self.panel or 0) then
          self.panel = panel
          local L = layout(game)
          if L.full and panelBox then
            local b = panelBox(panel)
            if b then game.save.currentBox = b end
          end
        end
        self.col, self.row = c, r
        self.header = false
        return true
      end
      -- Second tap on the cell the cursor is already on: that is A, and it
      -- is queued as a REAL button press rather than reimplemented here.
      -- A on this grid means grab, or put down, or tick, or open the
      -- marking window, depending on four pieces of state; a touch path
      -- that decided any of that for itself would be a fifth answer to
      -- drift out of step with the other four.
      pcall(function() mod.input:tap(game, "a") end)
      return true
    end
    -- never assumed. Pics reach this screen through Assets.image, which is
    -- the seam a sprite mod shadows -- the README calls that a feature --
    -- so a 112x112 or 168x168 replacement is a thing that will happen, and
    -- a fixed 0.5/1.0 would have drawn it straight over its neighbours: a
    -- 2x pic overflows a BIG cell by a whole cell, a 3x one by two.
    --
    -- Integer factors both ways. Two-bit pixel art survives being halved
    -- or doubled and smears at 0.6, so this picks the nearest whole step
    -- that fits rather than the one that fills the cell exactly.
    local function scaleFor(w, h, cell)
      local m = math.max(w, h)
      if m <= 0 then return 1 end
      if m <= cell then return math.max(1, math.floor(cell / m)) end
      return 1 / math.ceil(m / cell)
    end

    local function picScale(img, cell)
      return scaleFor(img:getWidth(), img:getHeight(), cell)
    end

    -- exposed so the suite can check the arithmetic without a graphics
    -- context, which is where the overflow above was found
    self.picScale = picScale

    -- and the layout, so the full-screen arithmetic -- how many panels fit
    -- in which window -- can be asserted without drawing anything
    self.layout = function() return layout(game) end

    -- and this one so it can ask which scene a box ended up wearing --
    -- FAVOURITE resolves to one of the saved favourites, a 1.9.x save
    -- resolves from a bare string, and neither answer is visible from
    -- outside once the palette stopped carrying it
    self.paperIdOf = paperIdOf

    -- ------- overworld sprites from Wilds of Kanto
    --
    -- CLASSIC halves a battle pic into its cell (see the header above); a
    -- species that fits a whole sprite into that cell instead of a halved
    -- one is strictly better, and Wilds of Kanto
    -- (github.com/YoDrehDenSwagAuf/overworld-spawn-mod, id
    -- "overworld_wild_spawns") builds exactly that -- a per-species
    -- overworld sprite for its wilds and its followers, sized for a
    -- 28-pixel cell with room to spare. Nothing of that mod's art is
    -- copied into this repo: this asks it, at runtime, for a path and
    -- draws it, the same seam a sprite mod already shadows the battle
    -- pics through in picOf above.
    --
    -- Reached through the engine's own api.find (src/mods/Loader.lua:1002),
    -- not a manifest dependency, so this stays an optional enhancement: a
    -- handle is nil in every case the other mod is not really there --
    -- absent, disabled, failed, or not yet run -- and that one check is
    -- the whole absence path.
    --
    -- The sprite comes from that mod's own resolve() (its main.lua:374
    -- publishes render.spriteProviders; lib/sprite_providers.lua:1253 is
    -- the call). resolve() always answers with a table, never nil, and
    -- falls back to a black silhouette when every real provider fails --
    -- worse than the halved battle picture, which at least shows which
    -- Pokemon it is, so that provider id (lib/sprite_providers.lua:34) is
    -- treated as a miss exactly like a missing handle.
    --
    -- The def follows SpriteRenderer's own contract
    -- (src/render/SpriteRenderer.lua:140-149): one image, frames stacked
    -- vertically, and frame 0 -- the idle/down frame -- is the one this
    -- grid wants. Neither the frame size nor the sheet height is assumed;
    -- both come out of the image and def.frames, because other providers
    -- and that mod's own "true size" feature answer with other sizes.
    --
    -- BIG is untouched: its cell is 56, a battle pic already draws there
    -- at scale 1, and a 16-pixel sprite would have to be blown up four
    -- times to fill it -- the trade this feature makes does not exist in
    -- that layout.
    --
    -- Every call into the other mod's code is pcalled -- it is someone
    -- else's release cycle, and a throw in a draw loop takes the frame
    -- down -- and cached per MON on self.owSpriteCache for the life of this
    -- screen, because resolve() walks a provider chain and calling it twenty
    -- times a frame is not free. Per mon rather than per species is what
    -- issue #2 cost: see owSpriteFor.
    local OW_MOD_ID = "overworld_wild_spawns"
    local OW_BLACK_PROVIDER_ID = "black" -- SpriteProviders.ID.BLACK

    -- Keyed by the MON, not by its species (issue #2). A species key means
    -- the first Pokemon of a species to be drawn decides the picture for
    -- every other one of it in the box -- so a shiny and a normal Ludicolo
    -- came out identical, whichever of the two was resolved first. The mon
    -- table is the only thing that tells them apart without this screen
    -- having to guess which field another mod stores "shiny" in.
    --
    -- Weak keys, so a Pokemon released or withdrawn while this screen is
    -- open does not sit in the cache holding its own table alive.
    local function owSpriteFor(mon)
      local cache = self.owSpriteCache
      local key = mon
      local cached = cache[key]
      if cached ~= nil then return cached or nil end

      local function miss()
        cache[key] = false
        return nil
      end

      local ok, handle = pcall(mod.find, OW_MOD_ID)
      if not ok or not handle or not handle.exports then return miss() end
      local ex = handle.exports

      -- ------- two ways to ask, in the order they are known to work
      --
      -- The FIRST is the one that matters. That mod already draws these
      -- sprites in the vanilla party menu, and it does it by monkeypatching
      -- PartyMenu.drawIcon and resolving through its follower sprite
      -- service (lib/follower/sprite_service.lua:222,384) -- not through
      -- spriteProviders. So the party-menu resolver is the code path with
      -- a screenshot behind it, and asking anything else first would be
      -- preferring the tidier seam to the working one.
      --
      -- It takes the Pokemon rather than a species id, which is why it is
      -- handed the real mon: it reads form and shininess off it. The cache
      -- is still keyed by species, which is right for Gen 1 -- there are no
      -- shinies and no forms here -- and would be the thing to widen first
      -- if a mod ever added either.
      local function viaPartyIcon()
        local service = ex.follower and ex.follower.spriteService
        if not service or type(service.resolvePartyIconDef) ~= "function" then
          return nil
        end
        local okDef, def = pcall(function()
          return service:resolvePartyIconDef(mon, game)
        end)
        if not okDef or type(def) ~= "table" or not def.image then return nil end
        return def, service
      end

      -- The SECOND is spriteProviders, the documented general seam. It is
      -- kept because it answers for the wild/overworld styles the party
      -- resolver has no opinion on, and because it is the one that survives
      -- if that mod ever retires its party-menu patch.
      --
      -- style nil: the player's own Sprite Style setting, the respectful
      -- default -- whatever they picked for their followers is what they
      -- should see here too. variant nil: "normal", never shiny.
      local function viaProviders()
        local providers = ex.spriteProviders
        if not providers or type(providers.resolve) ~= "function" then
          return nil
        end
        local okResolve, result = pcall(function()
          -- `mon.species`, not the cache key: the key is the mon itself now
          -- (issue #2), while this chain still asks by species. The two were
          -- the same value before and are not any more.
          return providers:resolve(nil, mon.species, nil, game)
        end)
        if not okResolve or type(result) ~= "table" or not result.def
            or result.error or result.providerId == OW_BLACK_PROVIDER_ID then
          return nil
        end
        if not result.def.image then return nil end
        return result.def
      end

      local def, service = viaPartyIcon()
      if not def then def = viaProviders() end
      if not def then return miss() end

      -- The service's own loader when it answered, because it caches and it
      -- knows about that mod's true-colour handling; Assets.image otherwise,
      -- which is the engine's cache and the seam a sprite mod shadows.
      local img
      if service and type(service.getPartyIconImage) == "function" then
        local okOwn, own = pcall(function()
          return service:getPartyIconImage(def.image)
        end)
        if okOwn then img = own end
      end
      if not img then
        local okImg, loaded = pcall(Assets.image, def.image)
        if okImg then img = loaded end
      end
      if not img then return miss() end
      local okDim, iw, ih = pcall(function() return img:getWidth(), img:getHeight() end)
      if not okDim or not iw or not ih or iw <= 0 or ih <= 0 then return miss() end

      local frames = def.frames
      if type(frames) ~= "number" or frames < 1 then frames = 1 end
      local fh = ih / frames
      local okQuad, quad = pcall(love.graphics.newQuad, 0, 0, iw, fh, iw, ih)
      if not okQuad or not quad then return miss() end

      -- That mod's sprite defs carry the engine's `trueColor` flag, and its
      -- own convention is that UNSET means full colour -- `def.trueColor ~=
      -- false` is the exact test its provider chain uses
      -- (lib/sprite_providers.lua:119-125), and its party-menu patch marks
      -- the rect it draws for the same reason drawPic does below
      -- (lib/follower/sprite_service.lua:372). These sprites are coloured
      -- art, so this is nearly always true; it is read rather than assumed
      -- because that mod also serves luminance sheets with the flag off.
      local sprite = { image = img, quad = quad, w = iw, h = fh,
                       trueColor = def.trueColor ~= false }
      cache[key] = sprite
      return sprite
    end

    -- Which picture drawPic below draws for a cell -- the option, the
    -- CLASSIC-only gate, the cache and every fallback, all decided in one
    -- place. Exposed so the suite can check the seam without a graphics
    -- context, the same reason self.picScale is exposed above.
    local function spriteToDraw(mon)
      if owSpritesOn() and layout(game).cell == LAYOUT.classic.cell then
        local sprite = owSpriteFor(mon)
        if sprite then
          return { kind = "ow", sprite = sprite, trueColor = sprite.trueColor }
        end
      end
      local img, trueColor, path = picOf(game, mon)
      if img then
        -- The pack's own animation, on the surface that has room for it.
        -- CLASSIC's cell is 28 -- a battle pic is drawn halved there, and a
        -- twenty-cell grid of half-size animations is motion nobody asked
        -- for -- so this is BIG and full screen only, which is where the
        -- picture is shown at the size it was drawn.
        if layout(game).cell > LAYOUT.classic.cell then
          img = animFrameFor(path, img, self.paperTick)
        end
        return { kind = "battle", img = img, trueColor = trueColor }
      end
      return nil
    end
    self.spriteToDraw = spriteToDraw

    -- ------- full-colour art and the shade remap (issue #4)
    --
    -- sgbPalettes below hands every cell its species' four-colour SGB
    -- palette, and the renderer's shader reads the pixels under that zone as
    -- four DMG greys and maps them onto those four colours. That is right
    -- for a Gen 1 battle pic and wrong for anything already coloured: a
    -- Crystal-sprites mod's art has real RGB in it, so the brightness of
    -- each pixel picks an unrelated colour out of the ramp and the Pokemon
    -- comes out in somebody else's palette.
    --
    -- The engine's answer is not to drop the zone but to report the rect the
    -- coloured art covers: Renderer:endFrame splices every rect reported
    -- here into the pass as a `colors = false` zone and re-blits it
    -- unshaded over the colourised frame (PaletteFX.lua:226-274). The cell
    -- around the sprite keeps the species palette and the wallpaper keeps
    -- its own, so nothing else on the screen changes -- this is exactly what
    -- the engine's own summary screen does with its pic
    -- (src/ui/SummaryMenu.lua:118-124).
    --
    -- Vanilla art never carries the flag, so on a mod-free boot nothing is
    -- reported and the frame is the one 1.9.2 drew. Guarded through pcall
    -- for the same reason every other engine call in this file is: an engine
    -- old enough to have no markTrueColor draws what it drew before.
    -- Resolved on the first coloured picture drawn and remembered as false
    -- when there is nothing to resolve, so a draw loop that runs twenty
    -- times a frame asks once. `false` rather than nil, because nil is
    -- "not looked yet" and an engine without the function must not be
    -- looked up again every cell.
    local paletteFX
    local function markTrueColor(x, y, w, h)
      if w <= 0 or h <= 0 then return end
      if paletteFX == nil then
        local okFX, fx = pcall(require, "src.render.PaletteFX")
        paletteFX = okFX and type(fx) == "table"
          and type(fx.markTrueColor) == "function" and fx or false
      end
      if not paletteFX then return end
      pcall(paletteFX.markTrueColor, x, y, w, h)
    end

    -- ------- when the surface has opted out of the remap
    --
    -- True exactly when sgbPalettes emits its base zone as trueColor and
    -- therefore emits NO per-cell zones: a Gen 1 boot, a layout whose cells
    -- land on the tile grid, and a scene actually drawn under them. Those
    -- are the cells whose colours have to travel with the picture instead
    -- (see "ON A SCENE THERE ARE NO PER-CELL ZONES" in sgbPalettes).
    --
    -- The two conditions are written out rather than shared with that
    -- function because they are asked at different times -- zones before
    -- the frame, this during it -- and a cached answer between them would
    -- be a third thing to keep true.
    local function remapOff()
      -- Gold: ALWAYS. This answered false, and that is why every Pokemon
      -- on Gold came out grey, caught ones included.
      --
      -- The question this function asks is "is the engine's shade remap
      -- NOT going to colour these, so the picture has to carry its own?"
      -- On Gold the honest answer is yes, always: Game2 never runs the
      -- palette pass -- it does not even ask a state for uiSize -- so no
      -- zone is ever emitted and nothing else is coming. Answering false
      -- meant `species = nil` into paintPic and four DMG greys on screen,
      -- while the file that wrote it believed Gold was colouring its own
      -- pictures.
      --
      -- The tile-alignment tests below are about addressing a ZONE, and
      -- there are no zones here, so they are not asked on this path.
      if isGen2(game) then return true end
      local L = layout(game)
      if L.cell % 8 ~= 0 or L.gridX % 8 ~= 0 or L.gridY % 8 ~= 0
         or L.partyX % 8 ~= 0 or L.partyY % 8 ~= 0 then
        return false
      end
      if self.mode ~= "box" and not L.full then return false end
      local paper = paperOf(game.save.currentBox)
      if self.mode == "box" and self.paperPick then
        paper = WALLPAPER_BY_ID[self.paperPick.id] or paper
      end
      if not (paper and paper.palette) then return false end
      local okFX, FX = pcall(require, "src.render.PaletteFX")
      return okFX and type(FX.trueColorZone) == "function" or false
    end
    self.remapOff = remapOff

    -- the species' four colours put on the PICTURE, the same table the zone
    -- pass would have sent, and only when this screen has taken the zones
    -- away. No shader, no colours: DMG greys, which is what CLASSIC has
    -- always drawn.
    -- ------- WHERE A SPECIES' FOUR COLOURS COME FROM, PER GENERATION
    --
    -- Not the same place, and asking the wrong one is why every Pokemon on
    -- Gold came out grey. `PaletteFX.monPal` reads the GEN 1 pack
    -- (`data.palettes`, src/render/PaletteFX.lua:435-444) and answers nil
    -- on a Gold boot -- nil colours, no shader, four DMG greys, and a file
    -- that thinks it asked properly.
    --
    -- Gold keeps its own table and its own reader, and its own screens use
    -- them: `Palettes.monColors(data.gen2Palettes, species, shiny)`
    -- (src/ui/gen2/BoxMenu.lua:683-684). It answers the same shape --
    -- four colours, lightest first -- so only the question changes.
    --
    -- Shiny travels with the MON, not the species, which is why this takes
    -- one: Gold gives a shiny its own colour pair in the same table.
    local function monColours(species, mon)
      if isGen2(game) then
        local okP, P = pcall(require, "src.world.gen2.Palettes")
        if not (okP and type(P) == "table"
                and type(P.monColors) == "function") then
          return nil
        end
        local shiny = false
        if mon and mon.dvs then
          local okS, Stats = pcall(require, "src.pokemon.Stats")
          if okS and type(Stats.isShiny) == "function" then
            local ok, v = pcall(Stats.isShiny, mon.dvs)
            shiny = ok and v or false
          end
        end
        local ok, colours =
          pcall(P.monColors, game.data and game.data.gen2Palettes,
                species, shiny)
        return ok and colours or nil
      end
      local okFX, FX = pcall(require, "src.render.PaletteFX")
      if not okFX then return nil end
      return FX.monPal(game.data, species)
    end

    local function paintPic(img, dx, dy, k, species, mon, quad)
      local g = love.graphics
      local sh = nil
      local okFX, FX = pcall(require, "src.render.PaletteFX")
      if okFX and species and type(FX.shader) == "function" then
        local colors = monColours(species, mon)
        local ok, made = pcall(FX.shader)
        if colors and ok and made then
          local sent = pcall(FX.sendColors, made, colors)
          if sent and pcall(g.setShader, made) then sh = made end
        end
      end
      if quad then
        pcall(g.draw, img, quad, dx, dy, 0, k, k)
      else
        pcall(g.draw, img, dx, dy, 0, k, k)
      end
      if sh then pcall(g.setShader) end
    end

    -- ------- CRYSTAL ANIMATES ITS OWN POKEMON
    --
    -- Not every Gen 2 game does: Gold and Silver draw one still picture,
    -- and Crystal is the one that moves. The engine extracts that -- the
    -- species record carries `anim` with a `sheet` and a `count`
    -- (src/import/RomExtractorGen2.lua:1631) -- and the sheet is a COLUMN
    -- of whole pictures, the base one on top and `count` frames under it.
    --
    -- Which is the same shape as an overworld sprite sheet, so this is
    -- drawn the same way: one quad, moved down the strip. No files are
    -- probed and nothing is guessed; the frames were in the cartridge all
    -- along.
    --
    -- Unown resolves its animation from the LETTER, the way its picture
    -- does: each letter carries its own `anim`, and taking the species'
    -- would put letter A's movement on all twenty-six.
    local animSheets = {}
    local function crystalAnim(def, mon)
      if not def then return nil end
      local rec = def.anim
      local okU, Unown = pcall(require, "src.core.gen2.Unown")
      if okU and type(Unown) == "table" and def.id == Unown.SPECIES then
        local letter = mon and Unown.monLetter(mon)
        local named = letter and Unown.name(Unown.index(letter))
        local form = named and def.letters and def.letters[named]
        rec = (form and form.anim) or rec
      end
      if not (rec and rec.sheet and rec.count and rec.count > 0) then
        return nil
      end
      local hit = animSheets[rec.sheet]
      if hit == nil then
        local ok, img = pcall(Assets.image, rec.sheet)
        hit = (ok and img) or false
        animSheets[rec.sheet] = hit
      end
      if not hit then return nil end
      local size = hit:getWidth()
      local total = rec.count + 1          -- the base picture, then the frames
      local at = math.floor((self.paperTick or 0) / 6) % total
      local okQ, quad = pcall(love.graphics.newQuad, 0, at * size,
        size, size, hit:getWidth(), hit:getHeight())
      if not okQ or not quad then return nil end
      return hit, quad, size
    end

    local function drawPic(mon, x, y)
      local L = layout(game)
      local chosen = spriteToDraw(mon)
      if not chosen then return end
      if chosen.kind == "ow" then
        local sprite = chosen.sprite
        local k = scaleFor(sprite.w, sprite.h, L.cell)
        local w, h = sprite.w * k, sprite.h * k
        local dx, dy = x + (L.cell - w) / 2, y + (L.cell - h) / 2
        love.graphics.draw(sprite.image, sprite.quad, dx, dy, 0, k, k)
        if chosen.trueColor then markTrueColor(dx, dy, w, h) end
        return
      end
      local img = chosen.img
      local quad, qsize = nil, nil
      -- Crystal's own frames win over the still picture, but only where
      -- there is room to see them: CLASSIC draws a battle pic halved.
      if not chosen.trueColor and L.cell > LAYOUT.classic.cell then
        local sheet, q, size = crystalAnim(defOf(game, mon), mon)
        if sheet then img, quad, qsize = sheet, q, size end
      end
      local k = quad and scaleFor(qsize, qsize, L.cell) or picScale(img, L.cell)
      local w = (quad and qsize or img:getWidth()) * k
      local h = (quad and qsize or img:getHeight()) * k
      local dx, dy = x + (L.cell - w) / 2, y + (L.cell - h) / 2
      -- coloured art is drawn as it is: a shade remap is what RUINS it,
      -- which is the whole reason markTrueColor exists two lines down
      local remap = self.remapNow
      if remap == nil then remap = remapOff() end
      local species = (not chosen.trueColor) and remap and mon.species or nil
      paintPic(img, dx, dy, k, species, mon, quad)
      if chosen.trueColor then markTrueColor(dx, dy, w, h) end
    end

    -- ------- the marks
    --
    -- Small filled love.graphics primitives, bottom-left of the cell, over a
    -- white pad so they stay legible against a pic -- the Gen 1 font has no
    -- glyph for CIRCLE/SQUARE/TRIANGLE/HEART, so this is real vector art,
    -- not text (PLAN.md "3. MARKS"). Only the marks that are set are drawn.
    -- Every number below is `cell/28` of a CLASSIC one, so BIG's marks are
    -- exactly twice the size and never run outside their (twice as big)
    -- cell either.
    local function drawShape(name, cx, cy, size)
      if name == "CIRCLE" then
        love.graphics.circle("fill", cx, cy, size / 2)
      elseif name == "SQUARE" then
        love.graphics.rectangle("fill", cx - size / 2, cy - size / 2, size, size)
      elseif name == "TRIANGLE" then
        poly("fill", cx, cy - size / 2,
          cx - size / 2, cy + size / 2, cx + size / 2, cy + size / 2)
      elseif name == "HEART" then
        local r = size / 4
        love.graphics.circle("fill", cx - r, cy - r, r)
        love.graphics.circle("fill", cx + r, cy - r, r)
        poly("fill", cx - size / 2, cy - r,
          cx + size / 2, cy - r, cx, cy + size / 2)
      end
    end

    local function drawMarks(mon, x, y)
      if not anyMarks(mon) then return end
      local cell = layout(game).cell
      local k = cell / 28
      local size = 4 * k
      local gap = 1 * k
      local n = #MARK_ORDER
      local totalW = n * size + (n - 1) * gap
      local totalH = size
      local px = x + gap
      local py = y + cell - totalH - gap
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.rectangle("fill", px - gap, py - gap,
        totalW + 2 * gap, totalH + 2 * gap)
      love.graphics.setColor(0, 0, 0, 1)
      for i, name in ipairs(MARK_ORDER) do
        if getMark(mon, name) then
          local cx = px + (i - 1) * (size + gap) + size / 2
          drawShape(name, cx, py + size / 2, size)
        end
      end
    end

    -- ------- a palette per Pokemon
    --
    -- This is the reason BIG exists. A zone is a palette bound to a TILE
    -- rectangle (PaletteFX.zone takes tile coordinates), and the engine
    -- draws each one scissored through the shade-remap shader -- so twenty
    -- zones is twenty draws, not a hardware limit. The Game Boy could show
    -- four; nothing here has to.
    --
    -- `monPal` is the species' own palette, the same table the summary
    -- screen and the battle use. So a Charmander is orange, a Bulbasaur
    -- green and a Gengar purple, all at once, in the grid -- which is what
    -- Gen 3's storage actually looks like and what Gen 1 never had the
    -- hardware to draw.
    --
    -- CLASSIC gets none of it, and cannot: a 28-pixel cell is three and a
    -- half tiles, and half a tile cannot carry a zone.
    --
    -- This whole method is simply never CALLED on Gold: Game2:draw
    -- (src/core/Game2.lua:1334-1450) has no equivalent of Gen 1's
    -- `s:sgbPalettes(self)` walk (src/core/Game.lua:530-538), and layout()
    -- above reads CLASSIC there regardless, so it would return nil anyway.
    -- The wallpaper PALETTE this method would apply is inert on a Gold
    -- boot for that reason; the wallpaper PATTERN self:draw paints still
    -- draws, because that half is plain love.graphics and owns no seam
    -- Gold skips. Not a bug to chase -- there is no code path here to fix.
    function self:sgbPalettes(game)
      local L = layout(game)
      -- Everything here has to land on the tile grid: the cell, and both
      -- grid origins. Flooring a stray offset into tile coordinates would
      -- not fail -- it would quietly slide every palette four pixels off
      -- its sprite, which is the kind of wrong that looks like a rendering
      -- bug rather than a layout mistake.
      if L.cell % 8 ~= 0 or L.gridX % 8 ~= 0 or L.gridY % 8 ~= 0
         or L.partyX % 8 ~= 0 or L.partyY % 8 ~= 0 then
        return nil
      end
      local PaletteFX = require("src.render.PaletteFX")
      local tiles = L.cell / 8

      -- The BASE zone, first and covering the whole surface. Without it the
      -- only remapped pixels are the cells themselves and everything else
      -- composites black -- including the header and footer, which are
      -- drawn in black and therefore vanish. SummaryMenu does the same
      -- thing: a whole-screen palette, then the per-mon one on top of it,
      -- because the renderer draws later zones over earlier ones.
      --
      -- PaletteFX.whole() is hardcoded to the 160x144 tile grid, so it
      -- would cover a quarter of a BIG canvas and leave the rest black.
      -- The size comes from the layout instead.
      --
      -- The wallpaper's palette (PLAN.md "4. BOX NAMES and WALLPAPERS")
      -- replaces GRAYS here rather than adding a zone of its own, tinting
      -- the whole surface the same way SummaryMenu's own whole-screen
      -- palette does -- which is the entire reason the header and footer
      -- keep working under it. Only the box pane has a wallpaper; the party
      -- pane keeps plain GRAYS, and PLAIN itself carries no palette at all,
      -- so a box nobody has touched renders exactly what 1.5.2 rendered.
      -- and in FULL SCREEN the party pane wears the cursor box's scene too
      -- (see the party branch of self:draw), so the opt-out has to follow it
      -- there or that scene is flattened onto four greys -- the 1.10.1 bug,
      -- in the one pane nobody re-checked after fixing it.
      local paper = (self.mode == "box" or L.full)
        and paperOf(game.save.currentBox) or nil
      if self.mode == "box" and self.paperPick then
        -- the chooser previews on the background, so the palette has to
        -- follow the cursor too or the preview is drawn under the saved
        -- box's colours
        paper = WALLPAPER_BY_ID[self.paperPick.id] or paper
      end

      -- A wallpaper is NOT four shades waiting for a palette: shade() sets
      -- the scene's own RGB, and an artist's strip arrives already coloured.
      -- Tinting either of them through the shade-remap a second time is what
      -- made BIG grey -- the scene was painted, then flattened onto four
      -- tones of the same palette it was already using. So the surface under
      -- a wallpaper opts OUT of the remap and shows what was drawn.
      --
      -- The zone still has to be here and still has to be first: it is what
      -- covers the whole canvas, and the per-species cells below are drawn
      -- over it in order. PLAIN and the party pane have no wallpaper and
      -- keep plain GRAYS, so a box nobody has touched renders exactly what
      -- 1.5.2 rendered.
      -- An engine too old to know the opt-out gets the behaviour it always
      -- had, tint and all, rather than an error.
      -- ------- IN FULL SCREEN THE BASE ZONE ANSWERS FOR EVERY PANEL
      --
      -- `paper` above is the CURSOR's box, and on one box filling the glass
      -- that is the whole surface. In full screen it is not: several boxes
      -- are on screen at once, each wearing what its owner chose. If the
      -- cursor happened to sit on a box with no wallpaper, this fell
      -- through to the GRAYS zone -- and a GRAYS zone covers the WHOLE
      -- surface, so every other panel's painted scene was flattened onto
      -- four greys with it. One plain box greying out its neighbours,
      -- reported as the background going greyscale after a pinch (the pinch
      -- only ever moved the cursor).
      --
      -- So the question is not "does the cursor's box have a scene" but
      -- "is there painted art anywhere on this surface". If there is, the
      -- surface opts out of the remap and the panels keep their colours;
      -- the per-cell zones below are unaffected either way.
      local painted = paper and paper.palette
      if not painted and L.full and self.mode == "box" then
        for p = 0, panelsShown(L) - 1 do
          local pp = paperOf(panelBox(p))
          if pp and pp.palette then painted = pp.palette; break end
        end
      end
      local bare = painted
        and type(PaletteFX.trueColorZone) == "function"
        and PaletteFX.trueColorZone(0, 0, L.w / 8 - 1, L.h / 8 - 1)
      local zones = {
        bare or PaletteFX.zone((paper and paper.palette) or PaletteFX.GRAYS,
          0, 0, L.w / 8 - 1, L.h / 8 - 1),
      }

      -- ------- ON A SCENE THERE ARE NO PER-CELL ZONES
      --
      -- A zone is a RECTANGLE, and the shade remap inside it reads the red
      -- channel: a pale sky is r > 0.83 and lands on shade 0, which in a
      -- species palette is white. So a cell with a Pokemon in it had its
      -- WALLPAPER repainted -- white where the scene was light, the
      -- species' own colours where it was dark -- while the empty cell
      -- beside it kept the picture. The Pokedex shipped the same mistake
      -- and it was reported there first, as a white card under every caught
      -- Pokemon; it is the same bug on the same day.
      --
      -- The picture is innocent: a ripped front pic has its border white
      -- flood-filled to alpha 0 (ImageWriter.matteColor0), so nothing but
      -- the Pokemon is drawn. So the remap moves onto the picture itself --
      -- drawPic sends the species' colours through PaletteFX.shader() for
      -- exactly the cells that used to get a zone -- and the scene between
      -- and behind the cells is left alone, which is the whole point of
      -- having painted it.
      --
      -- With no scene (PLAIN, the party pane outside full screen) the base
      -- zone is a real palette, the surface IS being remapped, and the
      -- per-cell zones are still the only way a Pokemon gets its colours.
      -- A CEILING on the coloured cells.
      --
      -- Every zone is a blit of the whole canvas, scissored: twenty-one of
      -- them is what BIG has always paid, and full screen with eight
      -- panels would ask for a hundred and sixty. That is not a palette
      -- problem, it is a frame-rate one, so the first forty occupied cells
      -- get their species colours and the rest stay in the base tones --
      -- which on a wallpaper is what CLASSIC looks like anyway.
      local MAX_ZONES = 40
      local function add(set, mode, panel)
        for i, mon in ipairs(set) do
          if #zones >= MAX_ZONES then break end
          local colors = PaletteFX.monPal(game.data, mon.species)
          if colors then
            local x, y = cellRect(i - 1, mode, panel)
            local tx, ty = x / 8, y / 8
            zones[#zones + 1] =
              PaletteFX.zone(colors, tx, ty, tx + tiles - 1, ty + tiles - 1)
          end
        end
      end

      -- Only the pane on screen. The two panes overlap by design -- one is
      -- drawn at a time -- so emitting zones for both painted the party's
      -- palettes in stripes across the box grid, which is exactly what the
      -- first BIG screenshot showed.
      if not bare then
        if self.mode == "box" then
          if L.full then
            -- every panel on screen, in reading order, until the ceiling
            for p = 0, (L.acrossN or 1) * (L.downN or 1) - 1 do
              add(game.save.boxes[panelBox(p)] or {}, "box", p)
            end
          else
            add(boxList(game), "box")
          end
        else
          add(game.save.party, "party")
        end
        -- the one on the cursor is drawn where the cursor is, so it needs
        -- its own zone or it wears whatever the cell under it is wearing
        if self.held and self.held.mon then
          local colors = PaletteFX.monPal(game.data, self.held.mon.species)
          if colors then
            local x, y = cellRect(self.row * cols() + self.col)
            local tx, ty = x / 8, y / 8
            zones[#zones + 1] =
              PaletteFX.zone(colors, tx, ty, tx + tiles - 1, ty + tiles - 1)
          end
        end
      end
      -- the marking window, last, so it draws in clean greys over whichever
      -- species' zone happens to sit underneath its rect (PLAN.md "3.
      -- MARKS")
      if self.markWindow then
        local x, y, w, h = markWindowRect()
        zones[#zones + 1] =
          PaletteFX.zone(PaletteFX.GRAYS, x / 8, y / 8, (x + w) / 8 - 1, (y + h) / 8 - 1)
      end

      if not zones[1] then return nil end
      return zones
    end

    local function outline(x, y, w, h)
      love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
    end

    -- Every glyph in this font advances 8 pixels and the screen is 160
    -- wide, so a line beside a 4-pixel margin has room for nineteen of
    -- them and no more. 1.1.0 shipped a "SELECT:PARTY START:BOX" hint --
    -- twenty-two glyphs, 176 pixels -- and the tail simply ran off the
    -- right edge. Nothing is drawn now without being measured first.
    -- Both of these follow the SURFACE, not the Game Boy. 1.5.0 hardcoded
    -- 160 and a footer at y=132: on the 288-tall BIG canvas that put
    -- "B:EXIT" in the middle of the grid, printed over the Pokemon.
    local TEXT_X = 4
    -- A caption row: an 8-pixel glyph with a little air over and under it.
    -- Both bands are this tall, on either grid.
    local CAPTION_BAND = 14

    -- A caption that survives whatever is behind it. With SOLID bands this
    -- is Font.draw and nothing else: the band is opaque, the letters are
    -- black, there is nothing to solve.
    --
    -- Once the scene runs under the header it is. The first answer was a
    -- one-pixel halo around each glyph, and it was not enough -- a
    -- photograph of a sunset behind BOX 1 3/20 settled that: black letters
    -- on pink cloud, outlined or not, are letters nobody reads. Type needs
    -- a surface, not an edge.
    --
    -- So each caption gets a plate exactly its own size: opaque, in the
    -- scene's own lightest tone, the same colour the full-width band uses.
    -- The row still shows the wallpaper either side of the words -- which
    -- is the whole point of turning the band down -- and the words sit on
    -- something. Gen 3 does this too: the box name has its own plate over
    -- the wallpaper rather than a band across the screen.
    local inkColour = nil

    local function caption(text, x, y)
      -- With SOLID bands the caption is black on an opaque band and there
      -- is nothing to solve. Below SOLID it is black over a pale scene and
      -- white over a dark one, and nothing else -- no plate, no outline.
      if bandAlpha() and inkColour then
        local c = inkColour
        love.graphics.setColor(c[1] / 255, c[2] / 255, c[3] / 255, 1)
        local advance = Font.draw(text, x, y)
        love.graphics.setColor(0, 0, 0, 1)
        return advance
      end
      return Font.draw(text, x, y)
    end
    local function textMax() return layout(game).w - TEXT_X * 2 end
    local function footerY() return layout(game).h - 12 end

    local function fitTo(text, maxW)
      text = tostring(text or "")
      while #text > 1 and Font.width(text) > maxW do
        text = text:sub(1, #text - 1)
      end
      return text
    end

    local function fit(text) return fitTo(text, textMax()) end

    -- ------- WHAT'S NEW: the popup nobody asked for and everybody needed
    --
    -- "ho come la sensazione che nessuno vede le nuove feature". Three
    -- releases added a wallpaper per box, a full-screen layout, the boxes
    -- either side and a contest anybody can enter, and every one of them
    -- lives behind a menu or an option: a player who never opens OPTIONS
    -- never learns that FULL SCREEN exists, and a screen that looks the
    -- same as last week is a screen where nothing happened.
    --
    -- So: once per version, on the first open after an update or an
    -- install, this screen says what changed and WHERE the thing is. The
    -- pages are ordered by how hard the thing is to reach -- what you can
    -- see straight away first, what needs two menus last -- because that
    -- is the order in which somebody stops reading.
    --
    -- It is also in the BOX MENU, so it can be read again on purpose
    -- rather than only by accident.
    -- 1.22.x changed what the screen DOES -- fingers work on it now -- so
    -- this moves with it. The bugfix releases in between did not, and did
    -- not interrupt anybody.
    local NEWS_VERSION = "1.22.0"

    -- `hi` is the accent colour: the line that names the thing, and the
    -- contest. Drawn in RGB and marked trueColor so the shade remap leaves
    -- it alone -- otherwise the accent is mapped onto whichever of four
    -- greys the base zone happens to carry, which is no accent at all.
    local NEWS_ACCENT = { 32, 96, 208 }
    local NEWS = {
      {
        title = "TOUCH",
        lines = {
          { "Play it with", true },
          { "your fingers.", true },
          { "" },
          { "Tap a cell to" },
          { "point, tap it" },
          { "again to grab." },
          { "" },
          { "Drag: box to" },
          { "box. Pinch:" },
          { "cell size." },
        },
      },
      {
        title = "TURN IT ON",
        lines = {
          { "It ships OFF," },
          { "so nothing" },
          { "changes yet." },
          { "" },
          { "START - MODS -", true },
          { "OPTIONS - TOUCH", true },
          { "" },
          { "Made for" },
          { "phones." },
        },
      },
      {
        title = "WALLPAPERS",
        lines = {
          { "91 wallpapers,", true },
          { "one per box.", true },
          { "" },
          { "Places, drawn" },
          { "here and by 20" },
          { "artists." },
          { "" },
          { "Next page: how" },
          { "to change one." },
        },
      },
      {
        title = "SET A WALLPAPER",
        lines = {
          { "UP on the box" },
          { "name opens the" },
          { "BOX MENU." },
          { "" },
          { "Pick WALLPAPER.", true },
          { "" },
          { "Up, down: place" },
          { "Left, right: who" },
          { "SELECT: a" },
          { "favourite" },
        },
      },
      {
        title = "FULL SCREEN",
        lines = {
          { "The box fills", true },
          { "your whole", true },
          { "device, several", true },
          { "boxes at once.", true },
          { "" },
          { "It is off until" },
          { "you turn it on." },
          { "" },
          { "Next page: where" },
        },
      },
      {
        title = "TURN IT ON",
        lines = {
          { "OPTIONS, then" },
          { "MODS, then" },
          { "GEN 3 BOX, then", true },
          { "FULL SCREEN.", true },
          { "" },
          { "GRID is there" },
          { "too: CLASSIC" },
          { "fits more boxes," },
          { "BIG draws them" },
          { "bigger." },
        },
      },
      {
        title = "IN THE BOX",
        lines = {
          { "PEEK: the boxes", true },
          { "either side show" },
          { "at the edges." },
          { "" },
          { "MOVE MANY, in", true },
          { "the BOX MENU:" },
          { "A ticks, START" },
          { "moves them all." },
        },
      },
      {
        title = "THE CONTEST",
        lines = {
          { "Your wallpaper", true },
          { "can ship with", true },
          { "the mod.", true },
          { "" },
          { "320x144, four" },
          { "colours, looping" },
          { "left to right." },
          { "" },
          { "See CONTEST.md", true },
          { "on the mod page." },
        },
      },
    }

    local function newsSeen()
      local ok, value = pcall(function() return mod.save:get("newsSeen") end)
      return ok and value or nil
    end

    -- ------- WHEN THE PANEL IS ALLOWED TO OPEN ITSELF
    --
    -- Two cases, and only two: a FIRST INSTALL, and an update that actually
    -- carries the thing the panel talks about. Everything else stays quiet.
    --
    -- NEWS_VERSION is NOT the manifest's version and must never be wired to
    -- it. It is the version that last changed what the mod DOES, so a
    -- release that fixes a bug or repaints something leaves it alone and
    -- nobody is interrupted -- 1.21.1 through 1.21.4 all sit behind
    -- NEWS_VERSION 1.21.0 for exactly that reason. Bump it when a page here
    -- describes something a player can now do and could not before.
    --
    -- The comparison is OLDER-THAN, not DIFFERENT-FROM. `~=` was the bug:
    -- a save carrying a newer stamp than the build it is running -- somebody
    -- who tried a prerelease and went back to stable, or installed an older
    -- build on purpose -- differs from NEWS_VERSION, so the panel opened and
    -- announced features that the running build does NOT have. Older-than is
    -- false in that direction, so going back is silent.
    local function olderThan(seen, target)
      if seen == nil or seen == "" then return true end -- first install
      if seen == target then return false end
      local function parts(v)
        local out = {}
        -- a prerelease ("1.9.3-beta.1") compares on its release numbers; the
        -- tail is dropped rather than parsed, since the panel only ever asks
        -- "is there something new here", not which build of it
        for n in tostring(v):gmatch("%d+") do out[#out + 1] = tonumber(n) end
        return out
      end
      local a, b = parts(seen), parts(target)
      for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x < y end
      end
      return false
    end

    local function closeNews()
      self.news = nil
      pcall(function() mod.save:set("newsSeen", NEWS_VERSION) end)
    end
    self.closeNews = closeNews

    local function openNews()
      self.news = { page = 1 }
    end
    self.openNews = openNews
    self.newsPages = NEWS
    self.newsVersion = NEWS_VERSION

    -- armed here rather than on the first draw: a screen that has been
    -- opened is a screen that has been seen, and the alternative -- arming
    -- inside draw -- runs again every frame
    if olderThan(newsSeen(), NEWS_VERSION) then openNews() end
    self.newsOlderThan = olderThan

    -- The panel is written in CLASSIC pixels and drawn at whole scale, so
    -- BIG and full screen get the SAME page twice as big rather than the
    -- same page in a corner with tiny text. Font.draw has no scale of its
    -- own, so the transform carries it.
    local function newsScale(L)
      return math.max(1, math.floor(L.cell / 28))
    end
    local function newsRect(L)
      local k = newsScale(L)
      local w = math.min(L.w - 8, 152 * k)
      local h = math.min(L.h - 8, 136 * k)
      local x = math.floor((L.w - w) / 2)
      local y = math.floor((L.h - h) / 2)
      return x - x % 8, y - y % 8, w, h, k
    end
    self.newsRect = newsRect
    -- how wide a line may be IN FONT PIXELS: the panel less its margins,
    -- divided by the scale it is drawn at
    local function newsInner(L)
      local _, _, w, _, k = newsRect(L)
      return math.floor((w - 16 * k) / k)
    end
    self.newsInner = newsInner

    -- Wrapped at DRAW time against the panel, never at 16 characters in the
    -- source: the same page is read on a Game Boy screen and on a phone
    -- filling 640 pixels, and text broken for the narrow one reads as a
    -- ransom note on the wide one.
    local function wrapTo(text, maxW)
      local out, line = {}, nil
      for word in tostring(text or ""):gmatch("%S+") do
        local try = line and (line .. " " .. word) or word
        if Font.width(try) <= maxW or not line then
          line = try
        else
          out[#out + 1] = line
          line = word
        end
      end
      out[#out + 1] = line or ""
      return out
    end
    self.wrapNews = wrapTo

    local function drawNews()
      local page = NEWS[self.news and self.news.page or 1]
      if not page then return end
      local L = layout(game)
      local x, y, w, h, k = newsRect(L)
      local g = love.graphics
      g.setColor(1, 1, 1, 1)
      g.rectangle("fill", x, y, w, h)
      g.setColor(0, 0, 0, 1)
      outline(x, y, w, h)
      outline(x + 2, y + 2, w - 4, h - 4)

      local inner = newsInner(L)
      local scaled = k > 1 and pcall(function()
        g.push()
        g.translate(x, y)
        g.scale(k, k)
      end)
      -- if the transform did not take, the page is still drawn -- small,
      -- where it belongs, and readable -- rather than not at all
      local ox0, oy0 = x, y
      if scaled then ox0, oy0 = 0, 0 end
      local step = scaled and 1 or k
      local ty = oy0 + 8 * (scaled and 1 or k)
      local tx0 = ox0 + 8 * (scaled and 1 or k)
      local bottom = (scaled and (h / k) or h) + oy0
      g.setColor(0, 0, 0, 1)
      Font.draw(fitTo(Strings("%s %s", page.title, NEWS_VERSION), inner),
        tx0, ty)
      ty = ty + 14 * step
      for _, entry in ipairs(page.lines) do
        local text = type(entry) == "table" and entry[1] or entry
        local hi = type(entry) == "table" and entry[2]
        for _, line in ipairs(wrapTo(text, inner)) do
          if ty + 8 * step <= bottom - 14 * step then
            if hi then
              g.setColor(NEWS_ACCENT[1] / 255, NEWS_ACCENT[2] / 255,
                NEWS_ACCENT[3] / 255, 1)
            else
              g.setColor(0, 0, 0, 1)
            end
            Font.draw(line, tx0, ty)
            ty = ty + 10 * step
          end
        end
      end

      g.setColor(0, 0, 0, 1)
      local last = self.news.page >= #NEWS
      Font.draw(fitTo(Strings("%d/%d %s", self.news.page, #NEWS,
        last and "A:CLOSE" or "A:NEXT B:EXIT"), inner),
        tx0, bottom - 12 * step)
      if scaled then pcall(g.pop) end
      -- the panel is drawn in real colours, so it has to be reported as
      -- such or the frame's shade remap flattens the accent into a grey
      markTrueColor(x, y, w, h)
      g.setColor(0, 0, 0, 1)
    end
    self.drawNews = drawNews

    local function updateNews()
      local input = game.input
      if input:wasPressed("b") then
        closeNews()
      elseif input:wasPressed("a") or input:wasPressed("right")
             or input:wasPressed("start") then
        if self.news.page >= #NEWS then
          closeNews()
        else
          self.news.page = self.news.page + 1
        end
      elseif input:wasPressed("left") then
        self.news.page = math.max(1, self.news.page - 1)
      end
    end
    -- on `self` because self:update() is written ABOVE this point in the
    -- file: a local declared here is still nil when that function runs
    self.updateNews = updateNews

    -- ------- the wallpaper chooser, which draws almost nothing
    --
    -- The first cut of this put a panel over the grid, and the panel covered
    -- the one thing the player is trying to judge: the wallpaper. So the
    -- chooser has no window at all. It borrows the footer -- the line that
    -- normally names the Pokemon under the cursor -- and says the place and
    -- the hand, with the arrows that work:
    --
    --     FOREST        < ADMURIN >
    --
    -- Up and down move through the places, left and right through the hands,
    -- and the whole screen behind stays exactly what it will be if you press
    -- A. Nothing is hidden while you choose, which is the point of choosing
    -- on the box rather than in a menu.
    local function paperPickLine()
      local pick = self.paperPick
      if not pick then return nil end
      -- Until you move, the footer explains itself. The chooser has no
      -- window and no arrows drawn on the grid, which is what keeps the
      -- wallpaper visible -- and the price of that is that nothing on
      -- screen says the D-pad does anything. So the first thing it says is
      -- what to press; the moment you press it, it gets out of the way and
      -- shows the choice instead.
      if not pick.moved then
        return Strings("UP/DOWN SCENE"), Strings("L/R ARTIST")
      end
      local list = artFor(pick.id)
      local by = (list[math.max(1, math.min(#list, pick.art))] or list[1]).by
      if #list > 1 then by = "<" .. by .. ">" end
      -- a star would be a glyph this font does not have, so the mark is a
      -- word: you can see at a glance whether SELECT would add or remove
      if faveIndexOf(pick.id, pick.art) then by = by .. " FAV" end
      return pick.id, by
    end

    -- ------- the marking window
    --
    -- Drawn by the box screen itself, not a ChoiceBox (PLAN.md "3. MARKS"):
    -- a ChoiceBox is not opaque, so under BIG it would drop the canvas to
    -- 160x144 while the box screen underneath still draws at 320x288 -- the
    -- exact bug "the two layouts" in main.lua's header describes for every
    -- other menu this release adds. On a tile-aligned rect, sized and
    -- positioned by markWindowRect() so sgbPalettes's GRAYS zone lands on
    -- exactly the pixels this draws.
    local function drawMarkWindow()
      local win = self.markWindow
      if not win then return end
      local x, y, w, h = markWindowRect()
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.rectangle("fill", x, y, w, h)
      love.graphics.setColor(0, 0, 0, 1)
      outline(x, y, w, h)
      -- The chosen row wears the game's own arrow, in the left margin,
      -- exactly where ListMenu puts it (src/ui/ListMenu.lua:371). A box
      -- ruled around the text was what this drew before, and a thin black
      -- rectangle on a white panel beside black text is not a cursor --
      -- it reads as a border, and the window looked like it had no
      -- selection at all. The text starts one glyph further in to make
      -- room for it, and the outline is kept as a fallback for a boot
      -- where Theme did not load.
      local rowY = y + 4
      for i, name in ipairs(MARK_ORDER) do
        local text = fitTo((getMark(win.mon, name) and "*" or " ") .. Strings(name),
          w - 24)
        Font.draw(text, x + 16, rowY)
        if i == win.cursor then
          if Theme and Theme.cursor then
            Font.drawCode(Theme.cursor, x + 6, rowY)
          else
            outline(x + 4, rowY - 1, Font.width(text) + 14, 10)
          end
        end
        rowY = rowY + 10
      end
    end

    -- ------- the wallpaper pattern
    --
    -- Behind the cells, at low alpha, before anything else is drawn
    -- (PLAN.md "4. BOX NAMES and WALLPAPERS") -- the grid's cell outlines,
    -- pics and marks all draw on top of it. PLAIN draws nothing at all, so
    -- a box nobody has touched looks exactly like 1.5.2 did. Scissored to
    -- the grid rect so nothing here can bleed into the header or footer.
    -- ------- the wallpaper: the whole screen, not a panel
    --
    -- Gen 3's wallpaper IS the screen. The grid sits ON it: each slot is a
    -- pale square laid over the scene, and the scene carries on around and
    -- between the slots. 1.9.0-beta.1 had this inside out -- it drew the
    -- pattern only inside the grid rect, so the box looked like a textured
    -- panel on a white page, which is the one thing it should not look like.
    --
    -- Everything here is drawn from code: shapes and the four authored
    -- colours per theme, no art copied from anywhere (`modkit lint` stays
    -- green, and it would not if a single ROM pixel were involved).
    --
    -- The motion is slow and small on purpose -- this is behind twenty
    -- Pokemon -- and its phase is taken modulo each theme's own period, so a
    -- box left open for an hour draws what it drew in the first minute.
    -- ANIMATE off pins every phase at zero.
    -- The screen keeps the seams the suite and the offline renderer drive;
    -- the painting itself lives at mod scope now, because the Pokedex draws
    -- through it too.
    self.drawArt = drawArt
    self.reshade = reshade
    self.drawWallpaper = function(paper, w, h, style)
      return drawWallpaper(paper, w, h, style, self.paperTick)
    end

    -- ------- the slots, laid ON the wallpaper
    --
    -- This is the layer that makes it read as Gen 3: each cell is a pale
    -- square over the scene, so the wallpaper carries on around and between
    -- the slots while every Pokemon still sits on something light enough to
    -- be seen against.
    --
    -- Opaque enough to be a slot rather than a tint -- the wallpaper reads
    -- through it as a hint of what is behind, not as a pattern the Pokemon
    -- has to compete with. On PLAIN there is no wallpaper at all, so white
    -- on white draws nothing and the plain box looks exactly as it always
    -- did.
    local function drawCellWash(x, y, size)
      local alpha = slotAlpha()
      if alpha <= 0 then return end
      love.graphics.setColor(1, 1, 1, alpha)
      love.graphics.rectangle("fill", x, y, size, size)
      love.graphics.setColor(0, 0, 0, 1)
    end

    function self:draw()
      love.graphics.clear(1, 1, 1, 1)
      love.graphics.setColor(0, 0, 0, 1)
      -- asked ONCE a frame rather than once a cell: the answer reads the
      -- layout, the options and the save, and full screen draws up to a
      -- hundred and sixty cells
      self.remapNow = remapOff()

      -- The wallpaper covers the WHOLE surface, and everything else is drawn
      -- on top of it -- that is what makes this a box that is somewhere,
      -- rather than a panel of texture on a white page.
      --
      -- Then the title row and the footer are painted back to white, because
      -- they are black text: a sky or a night sky behind a caption is a
      -- caption nobody can read, and Gen 3 keeps its own header on a solid
      -- band for exactly this reason. Between those two bands the wallpaper
      -- runs edge to edge, including the margins around the grid.
      local L = layout(game)
      if L.full and self.mode == "party" then
        -- The party pane on a full-screen surface: the grid is six cells
        -- wherever it is drawn, so the scene behind it is the one the
        -- cursor's box was wearing -- crossing over with SELECT should not
        -- look like leaving the mod.
        local paper, style = paperOf(game.save.currentBox), artOf(game.save.currentBox)
        drawWallpaper(paper, L.w, L.h, style, self.paperTick)
        local band = bandAlpha()
        inkColour = captionInk(reshade(paper, style))
        if band ~= 0 then
          local tint = bandTint(reshade(paper, style))
          if tint then
            love.graphics.setColor(tint[1] / 255, tint[2] / 255, tint[3] / 255, band or 1)
          else
            love.graphics.setColor(1, 1, 1, band or 1)
          end
          love.graphics.rectangle("fill", 0, 0, L.w, CAPTION_BAND)
          love.graphics.rectangle("fill", 0, footerY() - 2, L.w, L.h - footerY() + 2)
        end
        love.graphics.setColor(0, 0, 0, 1)
      end
      if self.mode == "box" then
        -- while the WALLPAPER chooser is open the box wears whatever the
        -- cursor is sitting on, not what it was saved with: that IS the
        -- preview, and it costs nothing because this screen draws its own
        -- background anyway
        local paper, style
        if self.paperPick then
          paper = WALLPAPER_BY_ID[self.paperPick.id] or WALLPAPER_BY_ID.PLAIN
          local list = artFor(self.paperPick.id)
          style = list[math.max(1, math.min(#list, self.paperPick.art))]
        else
          paper = paperOf(game.save.currentBox)
          style = artOf(game.save.currentBox)
        end
        if L.full then
          -- one scene per PANEL, inside its own rectangle: each box wears
          -- what its owner chose, which is the whole point of a wallpaper
          -- per box -- and the preview under the chooser follows the panel
          -- the cursor is in, not all of them.
          -- the panel is as big as the cell GRID asked for, so its size
          -- comes off the layout rather than off a constant
          local PW, PH = L.panelW or PANEL_W, L.panelH or PANEL_H
          -- The surround is BLANK, and stays blank.
          --
          -- It used to carry the cursor box's own scene, stretched over the
          -- whole surface, on the argument that a plain margin read as
          -- "bande bianche antiestetiche". That argument was wrong, and
          -- from outside the code it looks like a bug rather than a
          -- choice: "LO SFONDO E' SOLO PER BOX. LO METTE ANCHE AL WRAPPER
          -- DELLE BOXES". Quite -- a wallpaper belongs to ONE box. Painting
          -- box 2's sky across the whole screen puts it behind boxes 1, 3
          -- and 4 as well, so a per-box setting silently became a
          -- per-screen one and the boxes that had their own scene looked
          -- like cut-outs pasted on somebody else's.
          --
          -- White here, and every scene confined to the panel that chose
          -- it. The margin is the table the boxes are lying on, not a room.
          love.graphics.setColor(1, 1, 1, 1)
          love.graphics.rectangle("fill", 0, 0, L.w, L.h)
          for p = 0, panelsShown(L) - 1 do
            local ox, oy = panelOrigin(L, p)
            local boxNum = panelBox(p)
            local pPaper, pStyle
            if self.paperPick and p == (self.panel or 0) then
              pPaper = paper
              pStyle = style
            else
              pPaper, pStyle = paperOf(boxNum), artOf(boxNum)
            end
            local okDraw = pcall(function()
              love.graphics.push()
              love.graphics.translate(ox - 4, oy)
              -- White under the panel FIRST, or a PLAIN box is not plain.
              -- drawWallpaper returns without painting anything on PLAIN
              -- (line 2542), so a box nobody has given a scene to used to
              -- let the whole-surface scene behind it -- the CURSOR's box,
              -- painted over everything a few lines up -- show straight
              -- through: four boxes on screen, one wallpaper chosen, and
              -- the other three wearing box 1's sea. Each panel is its own
              -- opaque rectangle now, so a panel shows what its owner
              -- picked and nothing else. The margins around the panels are
              -- still the cursor's scene, which is the part that was meant.
              love.graphics.setColor(1, 1, 1, 1)
              love.graphics.rectangle("fill", 0, 0, PW - 4, PH - 4)
              love.graphics.setColor(0, 0, 0, 1)
              drawWallpaper(pPaper, PW - 4, PH - 4, pStyle,
                self.paperTick)
              love.graphics.pop()
            end)
            if not okDraw then pcall(love.graphics.pop) end
          end

          -- ------- and the box after the last panel, sliced by the edge
          --
          -- The panels never divide the surface exactly: what is left over
          -- is a strip at the bottom in the hand and at the right side
          -- turned sideways. That strip is where the NEXT box shows through
          -- -- the same thing Pokemon Box does at the screen edge, put
          -- where this layout leaves the room.
          if peekOn() then
            local shown = panelsShown(L)
            local nextBox = panelBox(shown)
            local lastX, lastY = panelOrigin(L, shown - 1)
            local restY = lastY + PH
            local restX = lastX + PW
            local room = L.h - restY - 12
            if room >= 20 then
              -- portrait: the top rows of the next box, cut off below
              local okPeek = pcall(function()
                love.graphics.push()
                love.graphics.translate(L.gridX - 4, restY)
                drawWallpaper(paperOf(nextBox), PW - 4, room,
                  artOf(nextBox), self.paperTick)
                love.graphics.pop()
              end)
              if not okPeek then pcall(love.graphics.pop) end
              local cells = game.save.boxes[nextBox] or {}
              caption(fitTo(Strings("%s %d/%d", boxName(nextBox), #cells,
                Boxes.CAPACITY), PW - 8), L.gridX, restY)
              for c = 0, COLS - 1 do
                local x = L.gridX + c * L.cell
                local y = restY + 14
                if y + 8 < L.h - 12 then
                  drawCellWash(x, y, L.cell)
                  love.graphics.setColor(0, 0, 0, 0.25)
                  outline(x, y, L.cell, L.cell)
                  love.graphics.setColor(1, 1, 1, 1)
                  if cells[c + 1] then drawPic(cells[c + 1], x, y) end
                  love.graphics.setColor(0, 0, 0, 1)
                end
              end
            end
            -- ...and NOTHING at the sides.
            --
            -- Two versions of a side strip were tried here: the next box's
            -- column at the right margin, then the previous box's at the
            -- left as well. Both were reported the same way -- "dai lati ci
            -- sono ancora le box tagliate, e' ancora una merda" -- and the
            -- reason is that a margin in this layout is 40 pixels of white
            -- next to a panel that is 148: a column standing in it reads as
            -- a broken part of the box beside it, not as a neighbour.
            --
            -- PEEK stays what it is where it works: the strip UNDER the last
            -- panel when the surface leaves room for one, and the sliced
            -- neighbours in the single-box layouts, where the grid really is
            -- centred with a margin either side.
          end
        else
          drawWallpaper(paper, L.w, L.h, style, self.paperTick)
          -- ------- the boxes either side, sliced by the screen edge
          --
          -- Pokemon Box on the GameCube shows the neighbours cut off at
          -- both edges, and it is the one thing that made a wall of
          -- storage feel like a shelf rather than a page: you can see that
          -- there IS a box that way, and roughly how full it is, before you
          -- walk into it.
          --
          -- Here that is a narrow strip of each neighbour's own wallpaper
          -- with its first column of cells over it, drawn at the margins
          -- the grid already leaves. Nothing moves and nothing is clipped
          -- by hand: the strip is exactly as wide as the margin, so the
          -- screen's own edge does the cutting.
          if peekOn() and self.mode == "box" and not self.paperPick then
            local margin = L.gridX
            if margin >= 10 then
              for side = -1, 1, 2 do
                local n = ((game.save.currentBox - 1 + side) % Boxes.COUNT) + 1
                local ox = side < 0 and (margin - L.cell) or (L.w - margin)
                local okPeek = pcall(function()
                  love.graphics.push()
                  love.graphics.translate(ox, 0)
                  drawWallpaper(paperOf(n), L.cell, L.h, artOf(n), self.paperTick)
                  love.graphics.pop()
                end)
                if not okPeek then pcall(love.graphics.pop) end
                -- one column of that box's slots, so the strip reads as a
                -- box and not as a stripe of scenery
                local cells = game.save.boxes[n] or {}
                for r = 0, ROWS - 1 do
                  local y = L.gridY + r * L.cell
                  drawCellWash(ox, y, L.cell)
                  love.graphics.setColor(0, 0, 0, 0.25)
                  outline(ox, y, L.cell, L.cell)
                  love.graphics.setColor(1, 1, 1, 1)
                  local mon = cells[r * COLS + (side < 0 and COLS or 1)]
                  if mon then drawPic(mon, ox, y) end
                  love.graphics.setColor(0, 0, 0, 1)
                end
              end
            end
          end
        end
        -- BANDS: how much of the header and the footer the scene is allowed
        -- to have. SOLID is the Gen 3 band and stays the default; anything
        -- below it lets the wallpaper run edge to edge over the WHOLE
        -- screen, and the captions carry their own halo from there on.
        local band = bandAlpha()
        -- the bands and the ink read the palette the STYLE draws with, not
        -- the category's own: a night variant would otherwise get a caption
        -- chosen for the daytime one
        local shown = reshade(paper, style)
        inkColour = captionInk(shown)
        if band ~= 0 then
          local tint = bandTint(shown)
          if tint then
            love.graphics.setColor(tint[1] / 255, tint[2] / 255, tint[3] / 255,
              band or 1)
          else
            love.graphics.setColor(1, 1, 1, band or 1)
          end
          -- The band is the height of the CAPTION, not of the margin above
          -- the grid. In CLASSIC those are the same 14 pixels and always
          -- were; in BIG the margin is 32, so the title sat on a white slab
          -- with twenty-two empty pixels under it -- a white border across
          -- the top of the scene, which is what it was reported as.
          local capH = math.min(L.gridY - 2, CAPTION_BAND)
          if not L.full then
            love.graphics.rectangle("fill", 0, 0, L.w, capH)
          end
          love.graphics.rectangle("fill", 0, footerY() - 2, L.w, L.h - footerY() + 2)
        end
        love.graphics.setColor(0, 0, 0, 1)
      end

      local set = list()
      local total = cols() * rows()
      local onHeader = self.mode == "box" and self.header

      -- header: which box, how full, and which pane has the cursor
      local title
      if self.mode == "box" then
        title = Strings("BOX %d %d/%d", game.save.currentBox,
          #set, Boxes.CAPACITY)
      else
        title = Strings("PARTY %d/%d", #set, Party.MAX)
      end
      -- ------- the MENU button
      --
      -- 1.6.0 put six features behind the header and told nobody it was
      -- there. The footer hint that named it only ever drew on an EMPTY
      -- cell, because an occupied one shows the Pokemon's name instead --
      -- and the cell under the cursor is occupied nearly all the time. So
      -- the whole release was invisible unless you happened to press UP on
      -- the top row and notice something had changed.
      --
      -- A drawn button fixes that by being a thing on the screen rather
      -- than a move you have to already know. It is right-aligned on the
      -- title row, outlined so it reads as pressable, and it is the same
      -- MENU the header's A opens -- no new binding, no new state, just the
      -- affordance the header always needed.
      local hint = self.mode == "box" and not L.full and Strings("MENU") or nil
      local hintW = hint and Font.width(hint) or 0
      local hintX = layout(game).w - TEXT_X - hintW

      -- the title yields to the button rather than running under it: an
      -- eight-glyph box name plus " 20/20" is wider than a CLASSIC screen
      -- has left once the button has its corner.
      local shownTitle = hint
        and fitTo(title, hintX - TEXT_X - 6)
        or fit(title)
      if not (L.full and self.mode == "box") then
        caption(shownTitle, TEXT_X, 2)
      end

      if hint then
        caption(hint, hintX, 2)
        outline(hintX - 3, 0, hintW + 6, 11)
      end

      -- the cursor's own row (PLAN.md "the control scheme"): an outline
      -- around the title, sized to the text rather than the surface, so it
      -- reads on CLASSIC and BIG alike and never runs wider than fit()
      -- already guaranteed the text itself does not. With the button drawn
      -- the outline runs to its far edge, so the row reads as one selected
      -- thing with a button on it rather than two unrelated outlines.
      -- ...and not in full screen, where the cursor's mark is drawn around
      -- the panel's OWN name. Leaving this in painted an empty outlined box
      -- in the top-left corner of a screen that has no header row -- the
      -- MENU affordance of a layout that is not being used.
      if onHeader and not (L.full and self.mode == "box") then
        local right = hint and (hintX + hintW + 3)
          or (TEXT_X + Font.width(shownTitle) + 2)
        outline(TEXT_X - 2, 0, right - (TEXT_X - 2), 11)
      end

      -- One panel's worth of cells. In FULL SCREEN this runs once per
      -- panel with that panel's own box; everywhere else it runs once,
      -- exactly as it always did.
      local function drawCells(panel, cells)
        for i0 = 0, total - 1 do
          local x, y = cellRect(i0, nil, panel)
          local mon = cells[i0 + 1]
          drawCellWash(x, y, layout(game).cell)
          love.graphics.setColor(0, 0, 0, 0.25)
          outline(x, y, layout(game).cell, layout(game).cell)
          love.graphics.setColor(1, 1, 1, 1)
          if mon then drawPic(mon, x, y) end
          love.graphics.setColor(0, 0, 0, 1)
          if mon then drawMarks(mon, x, y) end
          -- a ticked slot, in MOVE MANY: a filled corner, because a tick
          -- has to read at a glance across twenty cells and an outline does
          -- not. Only in the box the ticks belong to.
          if self.moveMany and self.many[i0 + 1]
             and game.save.currentBox == self.manyBox
             and (panel == nil or panelBox(panel) == self.manyBox) then
            local size = math.max(4, math.floor(L.cell / 4))
            love.graphics.setColor(0, 0, 0, 0.75)
            love.graphics.rectangle("fill", x + 1, y + 1, size, size)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.rectangle("fill", x + 2, y + 2, size - 2, size - 2)
            love.graphics.setColor(0, 0, 0, 1)
          end
        end
      end

      if L.full and self.mode == "box" then
        for p = 0, panelsShown(L) - 1 do
          local boxNum = panelBox(p)
          local cells = game.save.boxes[boxNum] or {}
          local ox, oy = panelOrigin(L, p)
          -- each panel says which box it is and how full, over its own grid
          local name = Strings("%s %d/%d", boxName(boxNum), #cells,
            Boxes.CAPACITY)
          local shown = fitTo(name, (L.panelW or PANEL_W) - 8)
          caption(shown, ox, oy)
          -- the cursor on a name: the same outline the single-box header
          -- uses, around this panel's own title, so "where am I" has an
          -- answer on a screen with eight boxes on it
          if self.header and p == (self.panel or 0) then
            outline(ox - 2, oy - 2, Font.width(shown) + 4, 12)
          end
          drawCells(p, cells)
        end
      else
        drawCells(nil, set)
      end

      -- Cursor last, so it sits over the art it is pointing at.
      --
      -- Corner brackets rather than a box: a one-pixel outline is what
      -- 1.5.x drew, and on a 56-pixel cell it is a hairline you have to
      -- hunt for -- and it competes with the cell outlines, which are the
      -- same shape one pixel away. Brackets read as a cursor at any size,
      -- and they leave the middle of the cell clear so the Pokemon under
      -- them is not fenced in.
      --
      -- Both numbers scale with the cell: 2px arms of 9 on CLASSIC, 4px
      -- arms of 18 on BIG.
      local cx, cy = cellRect(self.row * cols() + self.col, nil, self.panel)
      -- on the header the outline above is the cursor; the grid keeps none,
      -- so there is never more than one place on screen the cursor reads as
      -- being
      if not onHeader then
        local cell = layout(game).cell
        local t = math.max(1, math.floor(cell / 14))
        local arm = math.floor(cell / 3)
        local x0, y0 = cx - t, cy - t
        local x1, y1 = cx + cell, cy + cell
        local function bracket(bx, by, dx, dy)
          love.graphics.rectangle("fill", bx, by, dx * arm, t)
          love.graphics.rectangle("fill", bx, by, t, dy * arm)
        end
        love.graphics.rectangle("fill", x0, y0, arm, t)
        love.graphics.rectangle("fill", x0, y0, t, arm)
        love.graphics.rectangle("fill", x1 - arm + t, y0, arm, t)
        love.graphics.rectangle("fill", x1, y0, t, arm)
        love.graphics.rectangle("fill", x0, y1, arm, t)
        love.graphics.rectangle("fill", x0, y1 - arm + t, t, arm)
        love.graphics.rectangle("fill", x1 - arm + t, y1, arm, t)
        love.graphics.rectangle("fill", x1, y1 - arm + t, t, arm)
      end

      -- the carried mon rides just above the cursor, clear of the grid
      if self.held then
        love.graphics.setColor(1, 1, 1, 1)
        drawPic(self.held.mon, cx, cy - 10)
        love.graphics.setColor(0, 0, 0, 1)
      end

      -- footer: the notice if one is fresh, else what the cursor is on. In
      -- MARK MODE it says so instead -- "there is no state you can be in
      -- without being told" (PLAN.md "3. MARKS") -- for as long as the mode
      -- stays on, ahead of the usual per-cell hint.
      -- while the chooser is open the footer belongs to it: the place on the
      -- left, the hand on the right, and the grid untouched behind
      local pickId, pickBy = paperPickLine()
      if pickId then
        caption(fit(pickId), TEXT_X, footerY())
        local w = Font.width(pickBy)
        caption(pickBy, layout(game).w - TEXT_X - w, footerY())
        drawMarkWindow()
        if self.news then drawNews() end
        return
      end

      local line
      if self.notice then
        local now = love.timer and love.timer.getTime() or 0
        if now - self.noticeAt < 1.5 then line = self.notice else self.notice = nil end
      end
      if not line and self.markMode then
        line = Strings("MARK MODE B:DONE")
      end
      if not line then
        -- nothing is "selected" on the header, so the cell under where the
        -- cursor used to be does not count as what it is "on"
        local mon = self.held and self.held.mon
          or (not onHeader and set[index()])
        if mon then
          line = Strings("%s :L%d", nameOf(game, mon), mon.level or 0)
        elseif onHeader then
          line = Strings("A:BOX MENU B:EXIT")
        elseif self.mode == "box" then
          -- FULL SCREEN has no header to press A on, so the footer says
          -- where the BOX MENU went: nowhere yet. That is the honest line
          -- while this mode is still being built.
          line = layout(game).full
            and Strings("UP:BOX NAME SEL:PARTY")
            or Strings("SEL:PARTY B:EXIT")
        else
          line = Strings("SEL:BOX B:EXIT")
        end
      end
      caption(fit(line), TEXT_X, footerY())

      -- the marking window, last, so it sits over the grid and the cursor
      drawMarkWindow()
      -- ...and WHAT'S NEW over even that: it owns the keys while it is
      -- open, so it has to own the screen too
      if self.news then drawNews() end
    end

    -- The button says there is a menu; this says how to reach it, once, on
    -- the way in. It goes through the ordinary notice channel, so it fades
    -- after a second and a half like every other line and the footer is
    -- back to naming what the cursor is on -- a hint that stayed would be
    -- competing with the thing it is pointing at.
    say(Strings("UP: BOX MENU"))

    return self
  end

  -- ------- TOUCH
  --
  -- Off by default; while it is off this returns before looking at
  -- anything. The pad keeps first refusal by contract, not by arithmetic
  -- here: a pointer that begins on a virtual control belongs to the pad for
  -- its whole life and never reaches this hook (docs/modding.md), so the
  -- d-pad and the fingers cannot fight over the same press.
  --
  -- `live` is the grid on screen; every use is guarded by "is it still the
  -- top of the stack", so a finger landing while a menu is open does
  -- nothing -- the state on top owns the screen, and this is not it.
  local live = nil

  do
    local TAP_SLOP = 12
    local DRAG_STEP = 40   -- travel that turns a drag into one box
    local DRAG_MAX = 3     -- a teleported pointer arrives as ONE huge delta
                           -- and would otherwise fling through every box
    local PINCH_STEP = 48

    local fingers, pinch = {}, nil

    local function count()
      local n = 0
      for _ in pairs(fingers) do n = n + 1 end
      return n
    end

    local function onTop(game)
      if not live then return false end
      local ok, top = pcall(function() return game.stack:top() end)
      return ok and top == live
    end

    local function touchOn()
      local ok, v = pcall(function() return mod.options:get("touch") end)
      return ok and v == true
    end

    local setGrid = setGridChoice

    local function beginPinch()
      if pinch or count() < 2 then return end
      local ids = {}
      for id in pairs(fingers) do ids[#ids + 1] = id end
      local a, b = fingers[ids[1]], fingers[ids[2]]
      local dx, dy = a.x - b.x, a.y - b.y
      local gap = math.sqrt(dx * dx + dy * dy)
      if gap < 16 then return end
      pinch = { a = ids[1], b = ids[2], gap = gap }
    end

    local function updatePinch()
      if not pinch then return false end
      local a, b = fingers[pinch.a], fingers[pinch.b]
      if not (a and b) then pinch = nil; return false end
      local dx, dy = a.x - b.x, a.y - b.y
      local gap = math.sqrt(dx * dx + dy * dy)
      local moved = gap - pinch.gap
      if math.abs(moved) < PINCH_STEP then return false end
      pinch.gap = gap
      return setGrid(moved > 0 and "big" or "classic")
    end

    mod.hooks:wrap("input.pointer", function(next, game, ev)
      if not (ev and touchOn() and onTop(game)) then return next(game, ev) end

      if ev.phase == "pressed" then
        if not ev.insideGame then return next(game, ev) end
        -- brought onto THIS screen's surface first: gameX/gameY are window
        -- units and the cells are not laid out in window units
        local ux, uy = live.toUI(ev.gameX, ev.gameY)
        fingers[ev.id] = { x = ux, y = uy, x0 = ux, y0 = uy, moved = false }
        beginPinch()
        return next(game, ev)
      end

      local f = fingers[ev.id]
      if not f then return next(game, ev) end

      if ev.phase == "moved" then
        f.x, f.y = live.toUI(ev.gameX, ev.gameY)
        if math.abs(f.x - f.x0) > TAP_SLOP
           or math.abs(f.y - f.y0) > TAP_SLOP then
          f.moved = true
        end
        if count() >= 2 then
          if not pinch then beginPinch() end
          if updatePinch() then return true end
          return next(game, ev)
        end
        -- One finger dragged walks the boxes. BOTH axes are offered and
        -- the screen decides which one means anything on the layout it is
        -- wearing: one box on the glass takes either, a column of panels
        -- scrolls vertically, a row of them horizontally. The first cut
        -- offered only the horizontal one, so full screen -- where the
        -- panels stack downwards on a phone -- had nothing to drag.
        local dx, dy = f.x - f.x0, f.y - f.y0
        local axis = (math.abs(dy) > math.abs(dx)) and "y" or "x"
        local travel = (axis == "y") and dy or dx
        local steps = math.floor(math.abs(travel) / DRAG_STEP)
        if steps > 0 and live.touchScroll then
          steps = math.min(steps, DRAG_MAX)
          f.x0, f.y0 = f.x, f.y
          -- dragging the content up shows what is further down the list
          local dir = travel > 0 and -1 or 1
          local moved = false
          for _ = 1, steps do
            if live.touchScroll(dir, axis) then moved = true end
          end
          if moved then return true end
        end
        return next(game, ev)
      end

      if ev.phase == "released" or ev.phase == "cancelled" then
        local wasPinch = pinch ~= nil
        fingers[ev.id] = nil
        if pinch and (ev.id == pinch.a or ev.id == pinch.b) then pinch = nil end
        if ev.phase == "cancelled" or f.moved or wasPinch then
          return next(game, ev)
        end
        if not live.hitAt then return next(game, ev) end
        local slot, panel = live.hitAt(f.x, f.y)
        if slot == nil then return next(game, ev) end
        if live.touchTap and live.touchTap(slot, panel) then return true end
        return next(game, ev)
      end

      return next(game, ev)
    end)
  end

  mod.content.screens:register(SCREEN, { new = function(game)
    local screen = newScreen(game)
    live = screen
    return screen
  end })

  -- ------- reaching it
  --
  -- Both hooks CALL NEXT FIRST and decorate what comes back, so another
  -- mod's row on the same menu survives instead of being rebuilt over.

  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" or not onStart() then return out end
    return mod.ui.insertBefore(out, "SAVE", {
      label = Strings("BOXES"),
      onSelect = function() mod.ui.push(game, SCREEN) end,
    })
  end)

  -- The Pokémon Center PC. Its box row is labelled "SOMEONE'S PC" until you
  -- meet Bill and "BILL'S PC" after (the engine gates on EVENT_MET_BILL), so
  -- anchoring on one label alone would silently stop working halfway through
  -- the game -- try both, and fall back to the front of the list.
  local BOX_ROWS = { "BILL'S PC", "SOMEONE'S PC" }

  mod.hooks:wrap("ui.pc.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" or not onPC() then return out end
    local row = {
      label = Strings("BOXES"),
      onSelect = function() mod.ui.push(game, SCREEN) end,
    }
    if isGen2(game) then
      -- On Gold this same hook fires at TWO menus: the storage system
      -- (src/ui/gen2/PcMenu.lua), which is what BOXES belongs in, and the
      -- player's own ITEM PC (src/ui/gen2/ItemPcMenu.lua), where it does
      -- not. Both carry WITHDRAW/DEPOSIT/MAILBOX rows, so a label is not a
      -- safe anchor -- but only the storage menu's rows carry an
      -- id == "changebox", and the item PC's never do.
      local isStorage = false
      for _, entry in ipairs(out) do
        if entry.id == "changebox" then
          isStorage = true
          break
        end
      end
      if not isStorage then return out end
      table.insert(out, 1, row)
      return out
    end
    for _, anchor in ipairs(BOX_ROWS) do
      for _, entry in ipairs(out) do
        if entry.label == anchor then
          return mod.ui.insertAfter(out, anchor, row)
        end
      end
    end
    table.insert(out, 1, row)
    return out
  end)
end
