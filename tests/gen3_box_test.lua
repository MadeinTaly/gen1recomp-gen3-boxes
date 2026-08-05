-- Standalone: luajit mods/gen3_box/tests/gen3_box_test.lua
--
-- Loads the mod through the headless loader and asserts its stated effect:
-- the screen exists, both entrances obey OPEN FROM, and the storage rules
-- that protect a save hold -- the party is never emptied, a box never
-- passes twenty, and a carried Pokemon is never dropped out of the save.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Runtime = require("src.mods.Runtime")
local Data = require("src.core.Data")
Data:load()

local DIR = os.getenv("GEN3_BOX_DIR") or "mods/gen3_box"
local run = T.sdk.loadMod(DIR, { data = Data })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")

-- ------- the screen exists and is the mod's own

local factory = Data.screens and Data.screens.Gen3Box
T.check(factory ~= nil, "the Gen3Box screen is registered")

-- ------- both entrances, driven through the engine's own hooks

local function passthru(_, items) return items end
local function labels(items)
  local out = {}
  for i, e in ipairs(items) do out[i] = e.label end
  return table.concat(out, "|")
end
local function startRows()
  return { { label = "POKéDEX" }, { label = "SAVE" }, { label = "OPTION" } }
end
local function pcRows(metBill)
  return {
    { label = metBill and "BILL'S PC" or "SOMEONE'S PC" },
    { label = "RED's PC" },
  }
end

local function has(items, label) return labels(items):find(label, 1, true) ~= nil end

local startOut = Runtime.call("ui.start_menu.items", passthru, {}, startRows())
local pcOut = Runtime.call("ui.pc.items", passthru, {}, pcRows(false))
T.check(has(startOut, "BOXES"), "the start menu gains a BOXES row by default")
T.check(has(pcOut, "BOXES"), "the Pokémon Center PC gains one too")

-- The PC's box row is "SOMEONE'S PC" before Bill and "BILL'S PC" after, so
-- an anchor that only knew one of them would stop working mid-game.
local afterBill = Runtime.call("ui.pc.items", passthru, {}, pcRows(true))
T.eq(afterBill[2].label, "BOXES", "the row sits under BILL'S PC after Bill")
local before = Runtime.call("ui.pc.items", passthru, {}, pcRows(false))
T.eq(before[2].label, "BOXES", "and under SOMEONE'S PC before him")

-- A menu this mod does not recognise still gets the row rather than losing it
local odd = Runtime.call("ui.pc.items", passthru, {}, { { label = "SOMETHING ELSE" } })
T.eq(odd[1].label, "BOXES", "an unrecognised PC menu keeps the row")

-- Another mod's row on the same menu survives: the wrap calls next() first
local shared = Runtime.call("ui.start_menu.items", function(_, items)
  table.insert(items, 1, { label = "DEXNAV" })
  return items
end, {}, startRows())
T.check(has(shared, "DEXNAV"), "another mod's start-menu row survives the wrap")

-- ------- the storage rules
--
-- The screen is driven the way the player drives it: fake input, one press
-- per update, asserting on save.boxes / save.party afterwards.

local function mon(species, level) return { species = species, level = level } end

local function fakeGame(boxMons, partyMons)
  local boxes = {}
  for i = 1, 12 do boxes[i] = {} end
  for i, m in ipairs(boxMons or {}) do boxes[1][i] = m end
  local pressed = {}
  return {
    data = Data,
    save = { boxes = boxes, currentBox = 1, party = partyMons or {} },
    stack = { pop = function() end },
    input = { wasPressed = function(_, key) return pressed[key] end },
    press = function(key) pressed = {}; pressed[key] = true end,
  }
end

local function ids(list)
  local out = {}
  for i, m in ipairs(list) do out[i] = m.species end
  return table.concat(out, ",")
end

-- pick up, move, put down
local game = fakeGame({ mon("PIKACHU", 5), mon("ABRA", 7) })
local screen = factory.new(game)
game.press("a"); screen:update()
T.eq(#game.save.boxes[1], 1, "picking one up takes it out of the box")
game.press("right"); screen:update()
game.press("a"); screen:update()
T.eq(#game.save.boxes[1], 2, "putting it down returns it")

-- an occupied slot swaps rather than overwriting
game = fakeGame({ mon("A", 1), mon("B", 2), mon("C", 3) })
screen = factory.new(game)
game.press("a"); screen:update()
game.press("right"); screen:update()
game.press("a"); screen:update()
T.eq(ids(game.save.boxes[1]), "B,A", "dropping on an occupied slot swaps the two")

-- B while carrying puts it back instead of losing it
game = fakeGame({ mon("SOLO", 9) })
screen = factory.new(game)
game.press("a"); screen:update()
game.press("b"); screen:update()
T.eq(#game.save.boxes[1], 1, "B puts the carried one back rather than dropping it")

-- the party may not be emptied, exactly as the vanilla PC refuses
game = fakeGame({}, { mon("LAST", 50) })
screen = factory.new(game)
game.press("select"); screen:update()
game.press("a"); screen:update()
T.eq(#game.save.party, 1, "the last party member cannot be picked up")

-- stepping off the right edge walks to the next box
game = fakeGame({})
screen = factory.new(game)
for _ = 1, 5 do game.press("right"); screen:update() end
T.eq(game.save.currentBox, 2, "walking off the right edge moves to the next box")

-- neither side may overflow: a full box swapped against a party mon leaves
-- the box at twenty and hands the displaced one back to the cursor
game = fakeGame({}, { mon("P1", 5), mon("P2", 5) })
for i = 1, 20 do game.save.boxes[1][i] = mon("F" .. i, 1) end
screen = factory.new(game)
game.press("select"); screen:update()
game.press("a"); screen:update()
game.press("select"); screen:update()
game.press("a"); screen:update()
T.eq(#game.save.boxes[1], 20, "a full box stays at twenty through a swap")
game.press("b"); screen:update()
T.check(#game.save.boxes[1] <= 20, "and never passes twenty when stowing")
T.eq(#game.save.party, 2, "the displaced one lands in the party instead")

-- both full: refuse, and lose nothing
game = fakeGame({}, {})
for i = 1, 20 do game.save.boxes[1][i] = mon("F" .. i, 1) end
for i = 1, 6 do game.save.party[i] = mon("P" .. i, 5) end
screen = factory.new(game)
game.press("a"); screen:update()
game.press("select"); screen:update()
game.press("b"); screen:update()
T.eq(#game.save.boxes[1], 20, "with the party full it goes back to the box")
T.eq(#game.save.party, 6, "and the party is left untouched")

-- ------- START opens the summary, B goes back
--
-- B means back and only back, the convention every other screen follows.
-- That is what frees START to be the summary: there is no longer a cell
-- where the way out disappears.

local Screens = require("src.ui.Screens")
local realPush = Screens.push
local pushed
Screens.push = function(_, id, arg) pushed = { id = id, mon = arg } end

game = fakeGame({ mon("PIKACHU", 5) })
screen = factory.new(game)
pushed = nil
game.press("start"); screen:update()
T.eq(pushed and pushed.id, "SummaryMenu", "START over a Pokémon opens its summary")
T.eq(pushed and pushed.mon and pushed.mon.species, "PIKACHU",
  "and hands the summary that very Pokémon")

-- over an empty cell there is nothing to show, and nothing to break
game = fakeGame({})
screen = factory.new(game)
pushed = nil
game.press("start"); screen:update()
T.check(pushed == nil, "START over an empty cell opens nothing")

-- B leaves, from any cell -- including a box with no empty one anywhere,
-- which is the case that made the earlier B-means-STATS arrangement a trap
local closed = false
game = fakeGame({})
for i = 1, 20 do game.save.boxes[1][i] = mon("F" .. i, 1) end
game.stack.pop = function() closed = true end
screen = factory.new(game)
game.press("b"); screen:update()
T.check(closed, "B leaves even when every cell is occupied")

-- but never while carrying one: it is shelved first
closed = false
game = fakeGame({ mon("SOLO", 9) })
game.stack.pop = function() closed = true end
screen = factory.new(game)
game.press("a"); screen:update()
game.press("b"); screen:update()
T.check(not closed, "B does not leave while carrying a Pokémon")
T.eq(#game.save.boxes[1], 1, "it shelves it instead")
game.press("b"); screen:update()
T.check(closed, "and the next B leaves")
Screens.push = realPush

-- ------- walking off the edge changes box

game = fakeGame({})
screen = factory.new(game)
game.press("left"); screen:update()
T.eq(game.save.currentBox, 12, "stepping off the left edge wraps to box 12")
game.press("right"); screen:update()
T.eq(game.save.currentBox, 1, "and back off the right edge to box 1")

-- ------- nothing drawn may run off the 160-pixel screen
--
-- 1.1.0's footer hint was twenty-two glyphs at 8 pixels each: 176 wide on a
-- 160-wide screen, with the tail off the edge. Every string the screen
-- draws is collected here and measured.

local Font = require("src.render.Font")
Font.load(Data)
local realDraw, realBox = Font.draw, Font.drawBox
local drawn = {}
Font.draw = function(text, x, y) drawn[#drawn + 1] = { text = text, x = x } end
Font.drawBox = function() end

local function collect(setup)
  drawn = {}
  local g = fakeGame({ mon("PIKACHU", 100) },
    { mon("CHARIZARD", 100), mon("BLASTOISE", 88) })
  local s = factory.new(g)
  if setup then setup(g, s) end
  s:draw()
  return drawn
end

local widest, worst = 0, ""
local function measure(lines)
  for _, line in ipairs(lines) do
    local w = line.x + Font.width(line.text)
    if w > widest then widest, worst = w, line.text end
  end
end

measure(collect())                                            -- box, on a mon
measure(collect(function(_, s) s.col = 4; s.row = 3 end))      -- box, empty cell
measure(collect(function(g)                                     -- specie ignota
  g.save.boxes[1][1] = { species = "MISSINGNO", level = 100 }
end))
measure(collect(function(g, s)                                  -- party pane
  g.press("select"); s:update()
end))
measure(collect(function(g, s)                                  -- party, empty cell
  g.press("select"); s:update(); s.col = 2; s.row = 1
end))
measure(collect(function(g, s)                                  -- carrying one
  g.press("a"); s:update()
end))
measure(collect(function(g, s)                                  -- box 12, full
  g.save.currentBox = 12
  for i = 1, 20 do g.save.boxes[12][i] = mon("NIDORANDER", 100) end
end))

Font.draw, Font.drawBox = realDraw, realBox
T.check(widest <= 160,
  ("every drawn line fits the 160px screen (widest %d: %q)"):format(widest, worst))


-- ------- auto-update wiring (engine >= the ModUpdate/ModIndex release)
--
-- The manifest's `github` field is what the launcher's updater and the
-- "Find mods" tab read. And ModUpdate.pickZipAsset prefers an asset named
-- exactly "<id>-<version>.zip" -- so the release file name is part of the
-- contract, not decoration. This asserts the pair actually match.

local Manifest = require("src.mods.Manifest")
local ModUpdate = require("src.mods.ModUpdate")

local fh = assert(io.open(DIR .. "/manifest.json", "rb"))
local body = fh:read("*a"); fh:close()
local declared = body:match('"github"%s*:%s*"([^"]+)"')
T.check(declared ~= nil, "the manifest declares a github repo for updates")
T.check(Manifest.parseGithub(declared) ~= nil,
  "and it parses as owner/repo (" .. tostring(declared) .. ")")

local id = body:match('"id"%s*:%s*"([^"]+)"')
local version = body:match('"version"%s*:%s*"([^"]+)"')
local wanted = id .. "-" .. version .. ".zip"
local picked = ModUpdate.pickZipAsset({
  { name = "Source code (zip)", browser_download_url = "x" },
  { name = wanted, browser_download_url = "y" },
}, id, version)
T.eq(picked and picked.name, wanted,
  "the release asset must be named " .. wanted)

-- ------- BOX HEALS
--
-- The whole feature is one function on one event: StateStack calls exit()
-- on pop and only on pop, so "the player closed the boxes" is a thing the
-- engine already tells us and there is nothing to detect.
--
-- These build a hurt Pokemon rather than a stub, because Pokemon.heal
-- writes hp, status AND every move's pp, and a test that only checked hp
-- would pass on a heal that quietly forgot the other two.

do
  local Pokemon = require("src.pokemon.Pokemon")
  local loader = run.loader
  loader.modOptions = loader.modOptions or {}
  loader.modOptions.gen3_box = loader.modOptions.gen3_box or {}
  local store = loader.modOptions.gen3_box

  local function hurt(species)
    local move = next(Data.moves)
    return { species = species, level = 20,
             stats = { hp = 60 }, hp = 7, status = "PSN",
             moves = { { id = move, pp = 1, ppUps = 0 } } }
  end
  local function isRested(m)
    return m.hp == m.stats.hp and m.status == nil and m.moves[1].pp > 1
  end

  -- OFF: closing must change nothing at all
  store.heal = false
  do
    local g = fakeGame({ hurt("PIKACHU") })
    local s = factory.new(g)
    s:exit()
    local m = g.save.boxes[1][1]
    T.eq(m.hp, 7, "BOX HEALS off leaves a stored Pokemon exactly as it was")
    T.eq(m.status, "PSN", "including its status")
  end

  -- ON: closing rests everything in storage
  store.heal = true
  do
    local g = fakeGame({ hurt("PIKACHU"), hurt("ABRA") })
    local s = factory.new(g)
    local m = g.save.boxes[1][1]
    T.check(not isRested(m), "the Pokemon starts hurt, so the check below means something")
    s:exit()
    T.check(isRested(g.save.boxes[1][1]), "closing the boxes rests what is in them")
    T.check(isRested(g.save.boxes[1][2]), "all of them, not just the first")
    T.eq(g.save.boxes[1][1].hp, 60, "to full HP")
    T.eq(g.save.boxes[1][1].status, nil, "with the status cleared")
    T.check(g.save.boxes[1][1].moves[1].pp > 1, "and the PP restored")
  end

  -- the party is NOT storage
  do
    local g = fakeGame({}, { hurt("BULBASAUR") })
    local s = factory.new(g)
    s:exit()
    T.check(not isRested(g.save.party[1]),
      "the party is left alone -- this screen is not a Pokemon Centre")
  end

  -- every box, not only the one that happened to be open
  do
    local g = fakeGame({})
    g.save.boxes[7][1] = hurt("GEODUDE")
    g.save.currentBox = 1
    local s = factory.new(g)
    s:exit()
    T.check(isRested(g.save.boxes[7][1]),
      "a Pokemon in a box you were not looking at is rested too")
  end

  -- and a deposit made during the visit is rested on the way out, which is
  -- the thing the feature is actually for
  do
    local g = fakeGame({}, { hurt("CHARMANDER"), mon("SQUIRTLE", 5) })
    local s = factory.new(g)
    g.press("select"); s:update()          -- cross to the party
    g.press("a"); s:update()               -- pick the hurt one up
    g.press("select"); s:update()          -- back to the box
    g.press("a"); s:update()               -- put it away
    T.eq(#g.save.boxes[1], 1, "the deposit landed")
    T.check(not isRested(g.save.boxes[1][1]), "and is still hurt while the screen is open")
    s:exit()
    T.check(isRested(g.save.boxes[1][1]), "then rests when the screen closes")
  end

  store.heal = false
end

-- ------- BIG: the surface, and a palette per Pokemon
--
-- The arithmetic is checked rather than eyeballed, for the reason the
-- footer taught in 1.2.1: 22 glyphs of 8 pixels came to 176 on a 160-wide
-- screen and the tail simply ran off. A zone that starts half a tile out,
-- or a grid that runs past the canvas, fails the same silent way.

do
  local PaletteFX = require("src.render.PaletteFX")
  local loader = run.loader
  loader.modOptions = loader.modOptions or {}
  loader.modOptions.gen3_box = loader.modOptions.gen3_box or {}
  local store = loader.modOptions.gen3_box

  local full = {}
  local species = {}
  for id in pairs(Data.pokemon) do species[#species + 1] = id end
  table.sort(species)
  for i = 1, 20 do full[i] = mon(species[((i - 1) % #species) + 1], 10) end

  -- CLASSIC keeps the surface and asks for no zones
  store.grid = "classic"
  do
    local g = fakeGame(full)
    local s = factory.new(g)
    T.eq(select(1, s:uiSize()), 160, "CLASSIC keeps the Game Boy surface")
    T.eq(select(2, s:uiSize()), 144, "in both directions")
    T.check(s:sgbPalettes(g) == nil,
      "and asks for no zones -- a 28-pixel cell is three and a half tiles")
  end

  store.grid = "big"
  do
    local g = fakeGame(full, { mon(species[1], 5) })
    local s = factory.new(g)
    local w, h = s:uiSize()
    T.eq(w, 320, "BIG asks for a 320-wide surface")
    T.eq(h, 288, "and 288 tall")
    T.check(w <= 640 and h <= 576,
      "within Renderer.MAX_UI_WIDTH/HEIGHT, or setUISize silently refuses it")

    -- Species palettes come from the ROM-derived dataset; CI boots the
    -- 3-species fixture, which carries none, and monPal then has nothing
    -- to return. The gate reports which way it went rather than skipping
    -- in silence.
    local havePalettes = PaletteFX.monPal(Data, species[1]) ~= nil
    T.check(true, havePalettes
      and "species palettes present: the colour checks ARE running"
      or "fixture dataset: no species palettes, colour checks skipped")

    local zones = havePalettes and s:sgbPalettes(g) or nil
    if not havePalettes then goto skipColours end
    T.check(zones ~= nil, "BIG asks for zones")
    -- one per stored Pokemon, and NOT one per party member: the two panes
    -- overlap by design and only one is drawn, so zones for both would
    -- paint the party's palettes across the box grid
    T.eq(#zones, 20, "one zone per stored Pokemon, from the visible pane only")

    -- every zone must sit on the tile grid and inside the canvas
    local bad = {}
    for i, z in ipairs(zones) do
      if z.x % 8 ~= 0 or z.y % 8 ~= 0 then
        bad[#bad + 1] = ("zone %d starts mid-tile (%d,%d)"):format(i, z.x, z.y)
      end
      if z.x + z.w > w or z.y + z.h > h then
        bad[#bad + 1] = ("zone %d runs off the canvas (%d+%d, %d+%d)")
          :format(i, z.x, z.w, z.y, z.h)
      end
      if z.w ~= 56 or z.h ~= 56 then
        bad[#bad + 1] = ("zone %d is %dx%d, not one cell"):format(i, z.w, z.h)
      end
    end
    T.eq(#bad, 0, "every zone is tile-aligned and on screen (" ..
      table.concat(bad, "; ") .. ")")

    -- and no two box cells may overlap, or one Pokemon wears another's colours
    local seen, clash = {}, 0
    for i = 1, 20 do
      local z = zones[i]
      local key = z.x .. "," .. z.y
      if seen[key] then clash = clash + 1 end
      seen[key] = true
    end
    T.eq(clash, 0, "no two cells share a zone")

    -- and each zone must sit EXACTLY on its cell, not merely on some tile:
    -- flooring a stray offset would slide the colour off the sprite
    local drift = {}
    for i = 1, 20 do
      local cx, cy = s.cellRectFor and s.cellRectFor(i - 1, "box") or nil
      local z = zones[i]
      -- recomputed from the layout the mod published, independently of it
      local col, row = (i - 1) % 5, math.floor((i - 1) / 5)
      local wantX, wantY = 16 + col * 56, 32 + row * 56
      if z.x ~= wantX or z.y ~= wantY then
        drift[#drift + 1] = ("zone %d at (%d,%d), cell at (%d,%d)")
          :format(i, z.x, z.y, wantX, wantY)
      end
    end
    T.eq(#drift, 0, "every zone sits exactly on its cell (" ..
      table.concat(drift, "; ") .. ")")

    -- the colours must actually differ between species, or the whole
    -- feature is twenty identical palettes
    local distinct = {}
    for _, z in ipairs(zones) do
      distinct[tostring(z.colors[2][1]) .. "," .. tostring(z.colors[2][2])] = true
    end
    local n = 0; for _ in pairs(distinct) do n = n + 1 end
    T.check(n > 1, ("the grid shows more than one palette (%d distinct)"):format(n))

    -- a carried Pokemon needs its own zone: it is drawn on the cursor, not
    -- in its cell, and would otherwise wear whatever is underneath
    g.press("a"); s:update()
    T.check(s.held ~= nil, "picking one up")
    -- picking one up takes it out of the box list, so the count only holds
    -- if the carried one is zoned where the cursor is
    local held = s:sgbPalettes(g)
    T.eq(#held, 20, "the carried one keeps a zone of its own")

    ::skipColours::
  end

  store.grid = "classic"
end

  -- ------- a custom sprite must not spill into its neighbours
  --
  -- Pics come through Assets.image, the seam a sprite mod shadows, so a
  -- 112x112 or 168x168 replacement is a thing that happens. 1.5.0 scaled
  -- by a fixed 0.5/1.0 and drew a 2x pic a whole cell wide over the one
  -- next to it.
  do
    local loader2 = run.loader
    loader2.modOptions = loader2.modOptions or {}
    loader2.modOptions.gen3_box = loader2.modOptions.gen3_box or {}
    local store = loader2.modOptions.gen3_box
    local anySpecies = next(Data.pokemon)

    local function fakeImg(n)
      return { getWidth = function() return n end, getHeight = function() return n end }
    end
    local over = {}
    for _, grid in ipairs({ "classic", "big" }) do
      store.grid = grid
      local sc = factory.new(fakeGame({ mon(anySpecies, 5) }))
      local cell = grid == "classic" and 28 or 56
      for _, size in ipairs({ 40, 56, 64, 112, 160, 168, 224 }) do
        local k = sc.picScale(fakeImg(size), cell)
        local drawn = size * k
        if drawn > cell then
          over[#over + 1] = ("%s: %dpx pic drawn at %g (%gpx) in a %d cell")
            :format(grid, size, k, drawn, cell)
        end
        local whole = (k >= 1 and k % 1 == 0) or (k < 1 and (1 / k) % 1 == 0)
        if not whole then
          over[#over + 1] = ("%s: %dpx pic scaled by %g, not a whole step")
            :format(grid, size, k)
        end
      end
    end
    T.eq(#over, 0, "no picture ever spills its cell (" ..
      table.concat(over, "; ") .. ")")

    store.grid = "classic"
    local sc = factory.new(fakeGame({ mon(anySpecies, 5) }))
    T.eq(sc.picScale(fakeImg(56), 28), 0.5, "CLASSIC still halves a 56px pic")
    store.grid = "big"
    sc = factory.new(fakeGame({ mon(anySpecies, 5) }))
    T.eq(sc.picScale(fakeImg(56), 56), 1, "BIG still draws a 56px pic at scale 1")
  end

  -- ------- BIG's layout must survive the surface it asked for
  --
  -- 1.5.0 hardcoded the footer at y=132 and the line width at 160. On the
  -- 288-tall BIG canvas that printed "B:EXIT" across the middle of the
  -- grid, over the Pokemon. And sgbPalettes emitted zones for BOTH panes
  -- at once: the two overlap by design, since only one is drawn at a time,
  -- so the party's palettes appeared as stripes across the box grid.
  do
    local loader3 = run.loader
    loader3.modOptions = loader3.modOptions or {}
    loader3.modOptions.gen3_box = loader3.modOptions.gen3_box or {}
    local store = loader3.modOptions.gen3_box
    local anySpecies = next(Data.pokemon)

    local PaletteFX = require("src.render.PaletteFX")
    store.grid = "big"
    local box20 = {}
    for i = 1, 20 do box20[i] = mon(anySpecies, 10) end
    local g = fakeGame(box20, { mon(anySpecies, 5), mon(anySpecies, 5) })
    local s = factory.new(g)
    local W, H = s:uiSize()

    -- the grid, from the layout the mod actually uses
    local gx, gy, cell = 16, 32, 56
    local gridBottom = gy + 4 * cell

    -- every line the screen draws must land inside the surface, and the
    -- footer must sit BELOW the grid rather than on it
    local lines = {}
    local realDraw = Font.draw
    Font.draw = function(text, x, y)
      lines[#lines + 1] = { text = text, x = x, y = y,
                            w = Font.width(text) }
    end
    s:draw()
    Font.draw = realDraw

    local bad = {}
    for _, l in ipairs(lines) do
      if l.x + l.w > W then
        bad[#bad + 1] = ("%q runs to %d on a %d-wide surface")
          :format(l.text, l.x + l.w, W)
      end
      if l.y + 8 > H then
        bad[#bad + 1] = ("%q runs to %d on a %d-tall surface")
          :format(l.text, l.y + 8, H)
      end
      -- a line inside the grid rectangle is printed over the Pokemon
      if l.y + 8 > gy and l.y < gridBottom and l.x < gx + 5 * cell then
        bad[#bad + 1] = ("%q at y=%d is inside the grid (%d..%d)")
          :format(l.text, l.y, gy, gridBottom)
      end
    end
    T.eq(#bad, 0, "no text lands on the grid or off the surface (" ..
      table.concat(bad, "; ") .. ")")
    T.check(#lines > 0, "and the screen did draw some text")

    -- and the line may USE the wider surface: 1.5.0 measured against 160
    -- even on a 320-wide canvas, so a message was cut at nineteen glyphs
    -- with half the screen still empty beside it
    do
      local long = "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
      s.notice = long
      s.noticeAt = 1e9
      local shown
      local real = Font.draw
      Font.draw = function(text, x, y)
        if y >= gridBottom then shown = text end
      end
      s:draw()
      Font.draw = real
      s.notice = nil
      T.check(shown ~= nil, "the notice is drawn")
      T.check(shown and #shown > 19,
        ("BIG uses its width: %d glyphs shown of %d (19 would be the Game Boy)")
          :format(shown and #shown or 0, #long))
    end

    -- zones: one pane only, and none may overlap another
    if PaletteFX.monPal(Data, anySpecies) then
      local zones = s:sgbPalettes(g)
      T.eq(#zones, 20, "only the visible pane gets zones, not both")
      local clash = {}
      for i = 1, #zones do
        for j = i + 1, #zones do
          local a, b = zones[i], zones[j]
          if a.x < b.x + b.w and b.x < a.x + a.w
             and a.y < b.y + b.h and b.y < a.y + a.h then
            clash[#clash + 1] = i .. "/" .. j
          end
        end
      end
      T.eq(#clash, 0, "and no two zones overlap (" ..
        table.concat(clash, " ") .. ")")
    else
      T.check(true, "fixture dataset: zone overlap check skipped")
    end

    store.grid = "classic"
  end

run.release()
T.finish("gen3_box")
