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

-- A real miniature stack -- push / pop / top, states kept in `.states` --
-- so a menu this screen pushes (the box menu, SORT, JUMP TO BOX) can be
-- found and driven through its own :update() exactly as StateStack would
-- drive it, without a graphics context (src/core/StateStack.lua's shape,
-- minus enter/exit/draw, which nothing under test needs).
local function newStack()
  local stack = { states = {} }
  function stack:push(state) table.insert(self.states, state) end
  function stack:pop() return table.remove(self.states) end
  function stack:top() return self.states[#self.states] end
  return stack
end

-- find a pushed menu by its title, top of stack first -- the shape a test
-- wants when it has just pressed the key that should have opened one
local function findMenu(game, title)
  for i = #game.stack.states, 1, -1 do
    local state = game.stack.states[i]
    if state.title == title then return state end
  end
  return nil
end

local function fakeGame(boxMons, partyMons)
  local boxes = {}
  for i = 1, 12 do boxes[i] = {} end
  for i, m in ipairs(boxMons or {}) do boxes[1][i] = m end
  local pressed = {}
  return {
    data = Data,
    save = { boxes = boxes, currentBox = 1, party = partyMons or {} },
    stack = newStack(),
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

    -- zone 1 is the BASE: the whole surface, drawn first, with the per-mon
    -- zones on top. Without it only the cells are remapped and the rest of
    -- the frame composites BLACK -- header and footer included, since they
    -- are drawn in black. PaletteFX.whole() is not usable here: it is
    -- hardcoded to the 160x144 tile grid and would cover a quarter of this
    -- surface, which is the same bug wearing a helpful-looking name.
    local base = zones[1]
    T.eq(base.x, 0, "the base zone starts at the origin")
    T.eq(base.y, 0, "in both axes")
    T.eq(base.w, w, "and spans the whole surface width")
    T.eq(base.h, h, "and the whole height")
    -- one per stored Pokemon, and NOT one per party member: the two panes
    -- overlap by design and only one is drawn, so zones for both would
    -- paint the party's palettes across the box grid
    T.eq(#zones, 21, "the base zone plus one per stored Pokemon")

    -- every zone must sit on the tile grid and inside the canvas
    local bad = {}
    for i = 2, #zones do
      local z = zones[i]
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
    for i = 2, 21 do
      local z = zones[i]
      local key = z.x .. "," .. z.y
      if seen[key] then clash = clash + 1 end
      seen[key] = true
    end
    T.eq(clash, 0, "no two cells share a zone")

    -- and each zone must sit EXACTLY on its cell, not merely on some tile:
    -- flooring a stray offset would slide the colour off the sprite
    local drift = {}
    for i = 2, 21 do
      local z = zones[i]
      -- recomputed from the layout the mod published, independently of it
      local col, row = (i - 2) % 5, math.floor((i - 2) / 5)
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
    T.eq(#held, 21, "the carried one keeps a zone of its own")

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
      T.eq(#zones, 21, "the base plus the visible pane only, not both panes")
      local clash = {}
      for i = 2, #zones do
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

-- ------- Stats.ensure: the vanilla PC's guarded call, now here too
--
-- src/ui/BoxMenu.lua:85 calls Stats.ensure on every mon it moves into the
-- party, because box_struct carries no stat block. This screen has two
-- paths a mon can land in save.party by -- place() and stow() -- and both
-- must too, or a mon decoded out of an imported .sav reaches the party
-- with mon.stats nil and the HP bar nil-indexes it (#304/#233).

do
  -- place(): picked up out of a box, put down in the party
  local game = fakeGame({ mon("FIXMON_A", 10) })
  local screen = factory.new(game)
  T.check(game.save.boxes[1][1].stats == nil, "the box mon starts with no stats block")
  game.press("a"); screen:update()        -- pick it up
  game.press("select"); screen:update()   -- cross to the party
  game.press("a"); screen:update()        -- put it down
  local landed = game.save.party[1]
  T.check(landed ~= nil, "it landed in the party")
  T.check(type(landed.stats) == "table", "and gained a stats block")
  T.eq(landed.hp, landed.stats.hp, "at full HP, since it carried none of its own")
end

do
  -- stow(): B while carrying a box mon, its own box now full again because
  -- the cursor changed box while holding it -- so it overflows into the
  -- party instead of shelving back where it came from
  local game = fakeGame({}, {})
  local statless = { species = "FIXMON_A", level = 8 }
  game.save.boxes[1][1] = statless
  for i = 1, 20 do game.save.boxes[2][i] = mon("FIXMON_A", 5) end
  local screen = factory.new(game)
  game.press("a"); screen:update()     -- picks up the statless mon from box 1
  game.press("up"); screen:update()    -- onto the header
  game.press("right"); screen:update() -- box 2, already full
  game.press("down"); screen:update()  -- back into the grid, still carrying it
  game.press("b"); screen:update()     -- box 2 has no room: shelved into the party
  local landed = game.save.party[1]
  T.check(landed ~= nil, "the overflow landed in the party")
  T.check(type(landed.stats) == "table", "and it too gained a stats block")
end

-- ------- the header row
--
-- UP out of the grid's top row lands here, in box mode only; LEFT/RIGHT
-- change box from it, DOWN returns to the grid, and A opens the BOX MENU.
-- Nothing is "selected" on it, so START shows no summary. The deliberate
-- change PLAN.md calls out: with CURSOR WRAP on, UP from the top row now
-- stops on the header first, and UP again is what wraps to the bottom row.

do
  local loader = run.loader
  loader.modOptions = loader.modOptions or {}
  loader.modOptions.gen3_box = loader.modOptions.gen3_box or {}
  local store = loader.modOptions.gen3_box
  store.wrap = true

  local game = fakeGame({ mon("PIKACHU", 5) })
  local screen = factory.new(game)
  T.check(not screen.header, "the screen opens off the header")

  game.press("up"); screen:update()
  T.check(screen.header, "UP from the top row lands on the header")
  T.eq(screen.row, 0, "without moving the row underneath it")

  game.press("right"); screen:update()
  T.eq(game.save.currentBox, 2, "RIGHT from the header changes box")
  game.press("left"); screen:update()
  T.eq(game.save.currentBox, 1, "and LEFT changes it back")
  T.check(screen.header, "changing box from the header stays on the header")

  game.press("down"); screen:update()
  T.check(not screen.header, "DOWN from the header returns to the grid")

  -- the deliberate change: wrap now stops on the header first
  game.press("up"); screen:update()
  T.check(screen.header, "UP from the top row stops on the header, not the bottom")
  game.press("up"); screen:update()
  T.check(not screen.header, "and UP again leaves the header")
  T.eq(screen.row, 3, "wrapping to the bottom row")

  -- with wrap off, UP from the header goes nowhere
  store.wrap = false
  game = fakeGame({ mon("PIKACHU", 5) })
  screen = factory.new(game)
  game.press("up"); screen:update()
  T.check(screen.header, "UP from the top row still reaches the header")
  game.press("up"); screen:update()
  T.check(screen.header, "but UP again stays put with CURSOR WRAP off")
  store.wrap = true

  -- nothing is "selected" on the header
  local Screens = require("src.ui.Screens")
  local realPush = Screens.push
  local pushed
  Screens.push = function(_, id, arg) pushed = { id = id, mon = arg } end
  game = fakeGame({ mon("PIKACHU", 5) })
  screen = factory.new(game)
  game.press("up"); screen:update()
  game.press("start"); screen:update()
  T.check(pushed == nil, "START on the header opens no summary")
  Screens.push = realPush

  -- the header is only reachable in box mode
  game = fakeGame({}, { mon("SOLO", 9) })
  screen = factory.new(game)
  game.press("select"); screen:update() -- cross to the party
  game.press("up"); screen:update()
  T.check(not screen.header, "the party pane has no header to rise onto")
end

-- ------- the BOX MENU skeleton
--
-- A ListMenu, titled with the box's name, holding FIND / SORT / JUMP TO BOX
-- / NAME BOX / WALLPAPER / MARK MODE / CANCEL. FIND NEXT only joins the
-- list once a search is active (tested in "FIND and FIND NEXT" below).

do
  local game = fakeGame({})
  local screen = factory.new(game)
  game.press("up"); screen:update()
  game.press("a"); screen:update()

  local menu = findMenu(game, "BOX 1")
  T.check(menu ~= nil, "A on the header opens a menu titled with the box's name")
  T.check(menu == game.stack:top(), "and it is what is now on top of the stack")
  T.eq(labels(menu.items),
    "FIND|SORT|JUMP TO BOX|NAME BOX|WALLPAPER|MARK MODE|CANCEL",
    "holding FIND, SORT, JUMP TO BOX, NAME BOX, WALLPAPER, MARK MODE and CANCEL")

  for i, item in ipairs(menu.items) do
    if item.label == "CANCEL" then menu.index = i end
  end
  game.press("a"); menu:update()
  T.check(game.stack:top() == nil, "CANCEL closes the box menu, landing on the grid")
end

-- ------- JUMP TO BOX
--
-- The twelve boxes, each with its name and n/20, a * on the current one,
-- and no save prompt -- this screen writes no save.

do
  local game = fakeGame({ mon("PIKACHU", 5) })
  local screen = factory.new(game)
  game.press("up"); screen:update()
  game.press("a"); screen:update()
  local boxMenu = game.stack:top()
  for i, item in ipairs(boxMenu.items) do
    if item.label == "JUMP TO BOX" then boxMenu.index = i end
  end
  game.press("a"); boxMenu:update()

  local jumpMenu = game.stack:top()
  T.eq(#jumpMenu.items, 12, "JUMP TO BOX lists all twelve boxes")
  T.eq(jumpMenu.items[1].label, "*BOX 1", "the current box is marked with a *")
  T.eq(jumpMenu.items[1].right, "1/20", "and shows how full it is")
  T.eq(jumpMenu.items[2].label, "BOX 2", "the rest carry no mark")

  jumpMenu.index = 5
  game.press("a"); jumpMenu:update()
  T.eq(game.save.currentBox, 5, "choosing a box jumps to it")
  T.check(game.stack:top() == nil, "and closes both menus, landing on the grid")
  T.check(not screen.header, "off the header too")
end

-- ------- SORT + UNDO
--
-- BY DEX, BY LEVEL (descending), BY NAME, BY TYPE (first type, then dex),
-- each falling back to the current index -- a stable sort. UNDO restores
-- the pre-sort order, and refuses once the box it would restore into is no
-- longer a permutation of the snapshot.

do
  local function openSort(game, screen)
    game.press("up"); screen:update()  -- onto the header
    game.press("a"); screen:update()   -- the box menu
    local boxMenu = game.stack:top()
    for i, item in ipairs(boxMenu.items) do
      if item.label == "SORT" then boxMenu.index = i end
    end
    game.press("a"); boxMenu:update()
    return game.stack:top()            -- the SORT submenu
  end

  local function choose(list, game, label)
    for i, item in ipairs(list.items) do
      if item.label == label then list.index = i end
    end
    game.press("a"); list:update()
  end

  -- BY DEX
  do
    local game = fakeGame({ mon("FIXMON_C", 5), mon("FIXMON_A", 5), mon("FIXMON_B", 5) })
    local screen = factory.new(game)
    local sortMenu = openSort(game, screen)
    choose(sortMenu, game, "BY DEX")
    T.eq(ids(game.save.boxes[1]), "FIXMON_A,FIXMON_B,FIXMON_C",
      "BY DEX orders the box by dex number")
    T.check(not screen.header, "a chosen sort lands back on the grid")
    T.check(game.stack:top() == nil, "and closes every menu it opened")
  end

  -- BY LEVEL, descending: the strongest first
  do
    local game = fakeGame({ mon("FIXMON_A", 5), mon("FIXMON_A", 20), mon("FIXMON_A", 12) })
    local screen = factory.new(game)
    local sortMenu = openSort(game, screen)
    choose(sortMenu, game, "BY LEVEL")
    local levels = {}
    for i, m in ipairs(game.save.boxes[1]) do levels[i] = m.level end
    T.eq(table.concat(levels, ","), "20,12,5", "BY LEVEL puts the strongest first")
  end

  -- BY NAME
  do
    local function nick(name) return { species = "FIXMON_A", level = 5, nickname = name } end
    local game = fakeGame({ nick("CHARLIE"), nick("ALPHA"), nick("BETA") })
    local screen = factory.new(game)
    local sortMenu = openSort(game, screen)
    choose(sortMenu, game, "BY NAME")
    local names = {}
    for i, m in ipairs(game.save.boxes[1]) do names[i] = m.nickname end
    T.eq(table.concat(names, ","), "ALPHA,BETA,CHARLIE", "BY NAME orders alphabetically")
  end

  -- BY TYPE: first type, then dex (FIXMON_B is FIRE, FIXMON_A is GRASS,
  -- FIXMON_C is WATER)
  do
    local game = fakeGame({ mon("FIXMON_C", 5), mon("FIXMON_A", 5), mon("FIXMON_B", 5) })
    local screen = factory.new(game)
    local sortMenu = openSort(game, screen)
    choose(sortMenu, game, "BY TYPE")
    T.eq(ids(game.save.boxes[1]), "FIXMON_B,FIXMON_A,FIXMON_C",
      "BY TYPE orders FIRE, GRASS, WATER")
  end

  -- stable: two equal keys are not reshuffled
  do
    local a, b = mon("FIXMON_A", 5), mon("FIXMON_A", 5)
    local game = fakeGame({ a, b })
    local screen = factory.new(game)
    local sortMenu = openSort(game, screen)
    choose(sortMenu, game, "BY DEX")
    T.check(game.save.boxes[1][1] == a and game.save.boxes[1][2] == b,
      "two equal keys keep their current order")
  end

  -- the box stays compact and keeps every Pokemon it had
  do
    local species = { "FIXMON_A", "FIXMON_B", "FIXMON_C" }
    local mons = {}
    for i = 1, 20 do mons[i] = mon(species[(i % 3) + 1], i) end
    local game = fakeGame(mons)
    local screen = factory.new(game)
    local sortMenu = openSort(game, screen)
    choose(sortMenu, game, "BY LEVEL")
    T.eq(#game.save.boxes[1], 20, "the box stays at twenty")
    local seen = {}
    for _, m in ipairs(game.save.boxes[1]) do seen[m] = true end
    local allThere = true
    for _, m in ipairs(mons) do if not seen[m] then allThere = false end end
    T.check(allThere, "and keeps every Pokemon it had, only reordered")
  end

  -- UNDO restores the pre-sort order
  do
    local game = fakeGame({ mon("FIXMON_C", 5), mon("FIXMON_A", 5), mon("FIXMON_B", 5) })
    local before = ids(game.save.boxes[1])
    local screen = factory.new(game)
    local sortMenu = openSort(game, screen)
    choose(sortMenu, game, "BY DEX")
    T.check(ids(game.save.boxes[1]) ~= before, "the box actually changed")
    local sortMenu2 = openSort(game, screen)
    choose(sortMenu2, game, "UNDO")
    T.eq(ids(game.save.boxes[1]), before, "UNDO restores the pre-sort order")
  end

  -- UNDO refuses once the box is no longer a permutation of the snapshot
  do
    local game = fakeGame({ mon("FIXMON_C", 5), mon("FIXMON_A", 5), mon("FIXMON_B", 5) })
    local screen = factory.new(game)
    local sortMenu = openSort(game, screen)
    choose(sortMenu, game, "BY DEX")
    -- a Pokemon leaves the box after the sort
    table.remove(game.save.boxes[1], 1)
    local afterChange = ids(game.save.boxes[1])
    local sortMenu2 = openSort(game, screen)
    for i, item in ipairs(sortMenu2.items) do
      if item.label == "UNDO" then sortMenu2.index = i end
    end
    game.press("a"); sortMenu2:update()
    T.eq(ids(game.save.boxes[1]), afterChange, "a refused UNDO changes nothing")
    T.check(sortMenu2.footer ~= nil, "and it says so")
  end
end

-- ------- FIND and FIND NEXT
--
-- Every box, walking forward from the cursor and wrapping back around to
-- where it started; the party is never searched. SPECIES goes through the
-- real NamingScreen (src/ui/NamingScreen.lua): it pops itself and calls
-- onDone(name) on confirm, so driving it here means setting .glyphs and
-- calling :confirm() directly rather than typing letter by letter -- the
-- letter grid itself is the engine's own widget, not this mod's surface.

do
  local function openFind(game, screen)
    if not screen.header then
      game.press("up"); screen:update() -- onto the header
    end
    game.press("a"); screen:update()    -- the box menu
    local boxMenu = game.stack:top()
    for i, item in ipairs(boxMenu.items) do
      if item.label == "FIND" then boxMenu.index = i end
    end
    game.press("a"); boxMenu:update()
    return game.stack:top()             -- the FIND submenu
  end

  local function choose(list, game, label)
    for i, item in ipairs(list.items) do
      if item.label == label then list.index = i end
    end
    game.press("a"); list:update()
  end

  -- SPECIES: a substring match against the nickname, the species name and
  -- the raw species id -- a match in another box moves the cursor to it
  do
    local game = fakeGame({ mon("FIXMON_A", 5) })
    game.save.boxes[3][1] = { species = "FIXMON_B", level = 10, nickname = "BUDDY" }
    local screen = factory.new(game)
    local findMenu = openFind(game, screen)
    choose(findMenu, game, "SPECIES")
    local naming = game.stack:top()
    naming.glyphs = { "B", "U", "D" } -- matches "BUDDY", not "FIXMON B"'s own name
    naming:confirm()
    T.eq(game.save.currentBox, 3, "a nickname match in another box moves currentBox")
    T.eq(screen.col, 0, "and the cursor to it")
    T.eq(screen.row, 0, "")
    T.check(game.stack:top() == nil, "closing every menu FIND opened")
    T.check(not screen.header, "landing back on the grid")
  end

  -- SPECIES also matches the species' own name and the raw id
  do
    local game = fakeGame({})
    game.save.boxes[5][2] = mon("FIXMON_C", 9)
    local screen = factory.new(game)
    local findMenu = openFind(game, screen)
    choose(findMenu, game, "SPECIES")
    local naming = game.stack:top()
    naming.glyphs = { "F", "I", "X", "M", "O", "N", " ", "C" } -- "FIXMON C", the def name
    naming:confirm()
    T.eq(game.save.currentBox, 5, "a species-name match is found across boxes")
    T.eq(screen.col, 1, "at its actual index")
  end

  -- a miss moves nothing
  do
    local game = fakeGame({ mon("FIXMON_A", 5) })
    local screen = factory.new(game)
    local findMenu = openFind(game, screen)
    local col0, row0, box0 = screen.col, screen.row, game.save.currentBox
    choose(findMenu, game, "SPECIES")
    local naming = game.stack:top()
    naming.glyphs = { "Z", "Z", "Z" }
    naming:confirm()
    T.eq(game.save.currentBox, box0, "a miss leaves currentBox alone")
    T.eq(screen.col, col0, "and the cursor")
    T.eq(screen.row, row0, "exactly where it was")
  end

  -- an empty confirm (NamingScreen's own "declined" contract) starts no
  -- search and closes back to the grid quietly
  do
    local game = fakeGame({ mon("FIXMON_A", 5) })
    local screen = factory.new(game)
    local findMenu = openFind(game, screen)
    choose(findMenu, game, "SPECIES")
    local naming = game.stack:top()
    naming.glyphs = {}
    naming:confirm()
    T.check(game.stack:top() == nil, "an empty SPECIES search closes the menus")
    T.check(screen.findQuery == nil, "and remembers no query")
  end

  -- TYPE: built from game.data.pokemon, deduped and sorted
  do
    local game = fakeGame({ mon("FIXMON_A", 5) })
    game.save.boxes[2][1] = mon("FIXMON_C", 12) -- WATER
    local screen = factory.new(game)
    local findMenu = openFind(game, screen)
    choose(findMenu, game, "TYPE")
    local typeMenu = game.stack:top()
    T.eq(labels(typeMenu.items), "FIRE|GRASS|WATER",
      "TYPE lists every species' type, deduped and sorted")
    choose(typeMenu, game, "WATER")
    T.eq(game.save.currentBox, 2, "TYPE finds the WATER-type Pokemon")
    T.check(game.stack:top() == nil, "and closes SPECIES/TYPE/the box menu together")
  end

  -- MARK: the four symbols by word, matching mon.gen3Marks
  do
    local game = fakeGame({ mon("FIXMON_A", 5) })
    -- CIRCLE=1, SQUARE=2, TRIANGLE=3, HEART=4 (this mod's own accessor order)
    game.save.boxes[4][1] = { species = "FIXMON_B", level = 3, gen3Marks = "0010" }
    local screen = factory.new(game)
    local findMenu = openFind(game, screen)
    choose(findMenu, game, "MARK")
    local markFindMenu = game.stack:top()
    T.eq(labels(markFindMenu.items), "CIRCLE|SQUARE|TRIANGLE|HEART",
      "MARK offers the four symbols by word")
    choose(markFindMenu, game, "TRIANGLE")
    T.eq(game.save.currentBox, 4, "MARK finds the Pokemon carrying that mark")
  end

  -- FIND NEXT: a box-menu row present only while a search is active, and
  -- START on the header -- walking to the second match, then wrapping back
  -- to the first
  do
    local game = fakeGame({ mon("FIXMON_A", 1) })
    game.save.boxes[2][1] = mon("FIXMON_B", 2) -- first WATER/FIRE match by type
    game.save.boxes[4][1] = mon("FIXMON_B", 3) -- second match
    local screen = factory.new(game)

    local boxMenu0 = (function()
      game.press("up"); screen:update()
      game.press("a"); screen:update()
      return game.stack:top()
    end)()
    T.check(not has(boxMenu0.items, "FIND NEXT"),
      "FIND NEXT is absent from the box menu before any search")
    for i, item in ipairs(boxMenu0.items) do
      if item.label == "CANCEL" then boxMenu0.index = i end
    end
    game.press("a"); boxMenu0:update()

    local findMenu = openFind(game, screen)
    choose(findMenu, game, "TYPE")
    local typeMenu = game.stack:top()
    choose(typeMenu, game, "FIRE")
    T.eq(game.save.currentBox, 2, "the first FIRE match")

    -- FIND NEXT as a box-menu row
    game.press("up"); screen:update()
    game.press("a"); screen:update()
    local boxMenu1 = game.stack:top()
    T.check(has(boxMenu1.items, "FIND NEXT"),
      "FIND NEXT joins the box menu once a search is active")
    for i, item in ipairs(boxMenu1.items) do
      if item.label == "FIND NEXT" then boxMenu1.index = i end
    end
    game.press("a"); boxMenu1:update()
    T.eq(game.save.currentBox, 4, "FIND NEXT walks to the second match")
    T.check(game.stack:top() == nil, "and closes the box menu behind it")

    -- FIND NEXT as START on the header -- the header's one dead key
    game.press("up"); screen:update()
    T.check(screen.header, "on the header")
    game.press("start"); screen:update()
    T.eq(game.save.currentBox, 2, "START wraps back around to the first match")
  end
end

-- ------- MARKS
--
-- Storage through one accessor pair (mon.gen3Marks, a four-character
-- "0"/"1" string), the mode gate, the marking window, and its zone.

do
  -- the mode gate: A grabs with MARK MODE off, opens the window with it on
  do
    local game = fakeGame({ mon("FIXMON_A", 5) })
    local screen = factory.new(game)
    game.press("a"); screen:update()
    T.check(screen.held ~= nil, "A grabs a Pokemon with MARK MODE off")
    game.press("a"); screen:update() -- put it back so the box is as it was
    T.check(screen.held == nil, "")

    game.press("up"); screen:update()
    game.press("a"); screen:update()
    local boxMenu = game.stack:top()
    for i, item in ipairs(boxMenu.items) do
      if item.label == "MARK MODE" then boxMenu.index = i end
    end
    game.press("a"); boxMenu:update()
    T.check(screen.markMode, "MARK MODE toggles on from the box menu")
    T.check(game.stack:top() == nil, "and closes the box menu")

    game.press("a"); screen:update()
    T.check(screen.held == nil, "with MARK MODE on, A does not grab")
    T.check(screen.markWindow ~= nil, "it opens the marking window instead")
    T.check(screen.markWindow.mon == game.save.boxes[1][1],
      "on the Pokemon under the cursor")
  end

  -- toggling in the window writes gen3Marks; LEFT/RIGHT pick a symbol, A
  -- toggles it, B closes the window (and leaves MARK MODE on)
  do
    local game = fakeGame({ mon("FIXMON_A", 5) })
    local screen = factory.new(game)
    game.press("up"); screen:update()
    game.press("a"); screen:update()
    local boxMenu = game.stack:top()
    for i, item in ipairs(boxMenu.items) do
      if item.label == "MARK MODE" then boxMenu.index = i end
    end
    game.press("a"); boxMenu:update()

    game.press("a"); screen:update() -- open the window on FIXMON_A
    local win = screen.markWindow
    T.check(win ~= nil, "the window opened")

    game.press("a"); screen:update() -- toggle the symbol under the cursor
    T.check(game.save.boxes[1][1].gen3Marks ~= nil,
      "toggling a symbol writes gen3Marks")
    local firstMark = game.save.boxes[1][1].gen3Marks

    game.press("right"); screen:update() -- move to the next symbol
    game.press("a"); screen:update()     -- toggle it too
    T.check(game.save.boxes[1][1].gen3Marks ~= firstMark,
      "a second toggle changes the stored string again")
    local count = 0
    for c in game.save.boxes[1][1].gen3Marks:gmatch("1") do count = count + 1 end
    T.eq(count, 2, "two symbols are now set")

    game.press("b"); screen:update()
    T.check(screen.markWindow == nil, "B closes the window")
    T.check(screen.markMode, "without leaving MARK MODE")

    game.press("b"); screen:update()
    T.check(not screen.markMode, "the next B leaves MARK MODE instead (a back first)")
  end

  -- the value survives a serialize/decode round trip through SaveSerializer
  do
    local SaveSerializer = require("src.core.SaveSerializer")
    local save = { boxes = { { { species = "FIXMON_A", level = 5,
                                  gen3Marks = "1001" } } }, party = {} }
    local encoded = SaveSerializer.encode(save)
    local decoded, err = SaveSerializer.decode(encoded)
    T.check(decoded ~= nil, "the save decodes (" .. tostring(err) .. ")")
    T.eq(decoded.boxes[1][1].gen3Marks, "1001",
      "gen3Marks survives the round trip byte-for-byte")
  end

  -- the window's zone: tile-aligned, and appended last so it draws over
  -- whichever species' zone happens to sit under it (BIG only -- CLASSIC's
  -- 28px cell carries no zones at all, same as every other palette here)
  do
    local loader = run.loader
    loader.modOptions = loader.modOptions or {}
    loader.modOptions.gen3_box = loader.modOptions.gen3_box or {}
    local store = loader.modOptions.gen3_box
    store.grid = "big"

    local game = fakeGame({ mon("FIXMON_A", 5) })
    local screen = factory.new(game)
    game.press("up"); screen:update()
    game.press("a"); screen:update()
    local boxMenu = game.stack:top()
    for i, item in ipairs(boxMenu.items) do
      if item.label == "MARK MODE" then boxMenu.index = i end
    end
    game.press("a"); boxMenu:update()
    game.press("a"); screen:update() -- open the window on FIXMON_A

    local zones = screen:sgbPalettes(game)
    T.check(zones ~= nil, "BIG still asks for zones with the window open")
    local last = zones[#zones]
    T.eq(last.x, 16, "the window zone sits at the layout's own x")
    T.eq(last.y, 96, "and y")
    T.eq(last.w, 288, "spanning the window's width")
    T.eq(last.h, 96, "and height")
    T.eq(last.x % 8, 0, "tile-aligned in x")
    T.eq(last.y % 8, 0, "tile-aligned in y")
    T.eq(last.w % 8, 0, "tile-aligned in width")
    T.eq(last.h % 8, 0, "tile-aligned in height")
    T.check(last.colors == require("src.render.PaletteFX").GRAYS,
      "and drawn in plain greys, not the species' own palette")

    store.grid = "classic"
  end

  -- CLASSIC never grows a zone list for the window either -- there is
  -- still no zone list at all under a 28px cell
  do
    local game = fakeGame({ mon("FIXMON_A", 5) })
    local screen = factory.new(game)
    game.press("up"); screen:update()
    game.press("a"); screen:update()
    local boxMenu = game.stack:top()
    for i, item in ipairs(boxMenu.items) do
      if item.label == "MARK MODE" then boxMenu.index = i end
    end
    game.press("a"); boxMenu:update()
    game.press("a"); screen:update()
    T.check(screen:sgbPalettes(game) == nil,
      "CLASSIC still asks for no zones with the window open")
  end
end

-- ------- NAME BOX
--
-- The engine's own naming screen, 8 glyphs. NamingScreen's own declined
-- contract (src/ui/NamingScreen.lua) hands an empty confirm back as
-- whatever `default` was, never a raw "" -- there is no glyph pre-fill
-- (self.glyphs always starts empty), so confirming with nothing typed
-- reconfirms the box's current name, custom or not, rather than clearing
-- it. Typing back the box's own canonical "BOX n" is what actually clears
-- a custom name. Names live in mod.save under boxNames, keyed by box
-- number, and reads tolerate string keys in case a save has been through a
-- converter.

do
  local loader = run.loader
  loader.modSave = loader.modSave or {}
  loader.modSave.gen3_box = loader.modSave.gen3_box or {}
  local store = loader.modSave.gen3_box
  store.boxNames = nil

  local function openBoxMenu(game, screen)
    if not screen.header then
      game.press("up"); screen:update()
    end
    game.press("a"); screen:update()
    return game.stack:top()
  end

  local function choose(list, game, label)
    for i, item in ipairs(list.items) do
      if item.label == label then list.index = i end
    end
    game.press("a"); list:update()
  end

  local game = fakeGame({ mon("FIXMON_A", 5) })
  local screen = factory.new(game)

  local boxMenu = openBoxMenu(game, screen)
  T.eq(boxMenu.title, "BOX 1", "the box menu is titled BOX n before any name is set")
  choose(boxMenu, game, "NAME BOX")
  local naming = game.stack:top()
  T.eq(naming.default, "BOX 1", "NAME BOX defaults to the box's current name")
  T.eq(naming.maxLen, 8, "and allows 8 glyphs")

  naming.glyphs = { "H", "O", "M", "E" }
  naming:confirm()
  T.eq(store.boxNames and store.boxNames[1], "HOME",
    "confirming a name stores it in mod.save boxNames, keyed by box number")
  T.check(game.stack:top() == nil, "and lands back on the grid")

  local boxMenu2 = openBoxMenu(game, screen)
  T.eq(boxMenu2.title, "HOME",
    "boxName() -- and every caller through it, the box menu's own title here -- shows it")
  choose(boxMenu2, game, "NAME BOX")
  local naming2 = game.stack:top()
  T.eq(naming2.default, "HOME", "re-opening NAME BOX defaults to the name just set")
  naming2.glyphs = {}
  naming2:confirm()
  T.eq(store.boxNames[1], "HOME",
    "a confirm with nothing typed reconfirms the current name rather than clearing it")

  local boxMenu3 = openBoxMenu(game, screen)
  T.eq(boxMenu3.title, "HOME", "so the box is still named HOME")
  choose(boxMenu3, game, "NAME BOX")
  local naming3 = game.stack:top()
  naming3.glyphs = { "B", "O", "X", " ", "1" }
  naming3:confirm()
  T.check(store.boxNames == nil or store.boxNames[1] == nil,
    "typing the literal \"BOX 1\" back is what actually clears a custom name")

  local boxMenu3b = openBoxMenu(game, screen)
  T.eq(boxMenu3b.title, "BOX 1", "and the box goes back to being numbered")
  choose(boxMenu3b, game, "NAME BOX")
  local naming3b = game.stack:top()
  T.eq(naming3b.default, "BOX 1",
    "with no custom name, an empty confirm's default is already \"BOX n\"")
  naming3b.glyphs = {}
  naming3b:confirm()
  T.check(store.boxNames == nil or store.boxNames[1] == nil,
    "so an empty confirm on an unnamed box stores nothing there either")

  -- reads tolerate a save that has been through a converter and kept
  -- string keys instead of numeric ones
  store.boxNames = { ["1"] = "LEGACY" }
  local boxMenu4 = openBoxMenu(game, screen)
  T.eq(boxMenu4.title, "LEGACY",
    "a string-keyed boxNames entry reads the same as a numeric one")
  choose(boxMenu4, game, "CANCEL")

  store.boxNames = nil
end

-- ------- WALLPAPER
--
-- Each wallpaper is a pattern and a four-colour palette; the palette
-- replaces the whole-surface base zone self:sgbPalettes already emits
-- rather than adding one, so a wallpaper changes that zone's colours and
-- only that zone. PLAIN carries no palette at all, so it keeps emitting
-- exactly what 1.5.2 emitted.

do
  local PaletteFX = require("src.render.PaletteFX")
  local loader = run.loader
  loader.modSave = loader.modSave or {}
  loader.modSave.gen3_box = loader.modSave.gen3_box or {}
  local store = loader.modSave.gen3_box
  store.boxPapers = nil

  loader.modOptions = loader.modOptions or {}
  loader.modOptions.gen3_box = loader.modOptions.gen3_box or {}
  local optStore = loader.modOptions.gen3_box
  optStore.grid = "big"

  local function openBoxMenu(game, screen)
    if not screen.header then
      game.press("up"); screen:update()
    end
    game.press("a"); screen:update()
    return game.stack:top()
  end

  local function choose(list, game, label)
    for i, item in ipairs(list.items) do
      if item.label == label then list.index = i end
    end
    game.press("a"); list:update()
  end

  local game = fakeGame({ mon("FIXMON_A", 5), mon("FIXMON_B", 3) })
  local screen = factory.new(game)

  local zonesBefore = screen:sgbPalettes(game)
  T.check(zonesBefore ~= nil, "BIG asks for zones with the default wallpaper")
  T.check(zonesBefore[1].colors == PaletteFX.GRAYS,
    "PLAIN carries no palette of its own, so the base zone stays plain GRAYS")
  local beforeCount = #zonesBefore
  local beforeMon = {}
  for i = 2, #zonesBefore do beforeMon[i] = zonesBefore[i] end

  local boxMenu = openBoxMenu(game, screen)
  choose(boxMenu, game, "WALLPAPER")
  local wallMenu = game.stack:top()
  T.eq(labels(wallMenu.items), "PLAIN|STRIPES|CHECKS|DOTS|WAVES|NIGHT",
    "WALLPAPER lists the five patterns plus NIGHT")
  choose(wallMenu, game, "STRIPES")
  T.eq(store.boxPapers and store.boxPapers[1], "STRIPES",
    "choosing a wallpaper stores it in mod.save boxPapers, keyed by box number")
  T.check(game.stack:top() == nil, "and lands back on the grid")

  local zonesAfter = screen:sgbPalettes(game)
  T.check(zonesAfter[1].colors ~= PaletteFX.GRAYS,
    "STRIPES changes the base zone's colours")
  T.eq(#zonesAfter, beforeCount,
    "and only the base zone -- the zone count is unchanged")
  local drifted = false
  for i = 2, #zonesAfter do
    local a, b = zonesAfter[i], beforeMon[i]
    if not (b and a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h
            and a.colors == b.colors) then
      drifted = true
    end
  end
  T.check(not drifted, "and every per-Pokemon zone is untouched")

  -- CLASSIC still asks for no zones at all, wallpaper or not: a 28-pixel
  -- cell carries no zone, so the palette can only ever be a BIG thing
  optStore.grid = "classic"
  T.check(screen:sgbPalettes(game) == nil,
    "CLASSIC still asks for no zones with a wallpaper set")
  optStore.grid = "big"

  -- NIGHT is a palette in reverse, not a tint: its lightest-mapped entry is
  -- black and its darkest-mapped entry is white
  choose(openBoxMenu(game, screen), game, "WALLPAPER")
  choose(game.stack:top(), game, "NIGHT")
  local night = screen:sgbPalettes(game)[1].colors
  T.same(night[1], { 0, 0, 0 }, "NIGHT's lightest-mapped shade is black")
  T.same(night[4], { 255, 255, 255 }, "and its darkest-mapped shade is white")

  store.boxPapers = nil
  optStore.grid = "classic"
end

-- ------- PLACE CRY
--
-- On by default: every landing plays the cry of the Pokemon that landed --
-- a drop into an empty slot, the one put down in a swap, and the shelving
-- B does (stow). A refused placement plays nothing, because nothing
-- landed, and the option can turn the whole feature off.

do
  local Sound = require("src.core.Sound")
  local realPlayCry = Sound.playCry
  local calls
  Sound.playCry = function(_, _species)
    calls = calls + 1
    return nil
  end

  local loader = run.loader
  loader.modOptions = loader.modOptions or {}
  loader.modOptions.gen3_box = loader.modOptions.gen3_box or {}
  local store = loader.modOptions.gen3_box
  store.placeCry = true

  -- a drop into an empty slot
  do
    calls = 0
    local game = fakeGame({ mon("FIXMON_A", 5) })
    local screen = factory.new(game)
    game.press("a"); screen:update()      -- pick up
    game.press("right"); screen:update()
    game.press("a"); screen:update()      -- drop into the empty slot beside it
    T.eq(calls, 1, "a drop into an empty slot plays exactly one cry")
  end

  -- an occupied slot: the one put down in the swap
  do
    calls = 0
    local game = fakeGame({ mon("A", 1), mon("B", 2) })
    local screen = factory.new(game)
    game.press("a"); screen:update()
    game.press("right"); screen:update()
    game.press("a"); screen:update()      -- swap
    T.eq(calls, 1, "a swap plays exactly one cry, for the one put down")
  end

  -- B while carrying: the shelving stow() does lands it too
  do
    calls = 0
    local game = fakeGame({ mon("SOLO", 9) })
    local screen = factory.new(game)
    game.press("a"); screen:update()
    game.press("b"); screen:update()      -- stowed back into the box
    T.eq(calls, 1, "B shelving a carried Pokemon plays exactly one cry")
  end

  -- a refused placement plays nothing: nothing landed. The current box
  -- (wherever the cursor is, not necessarily where the carried mon started)
  -- and the party are both full, so stow() has nowhere to put it.
  do
    calls = 0
    local game = fakeGame({ mon("CARRY", 5) }, {})
    for i = 1, 6 do game.save.party[i] = mon("P" .. i, 5) end
    for i = 1, 20 do game.save.boxes[2][i] = mon("F" .. i, 1) end
    local screen = factory.new(game)
    game.press("a"); screen:update()      -- grab CARRY out of box 1
    game.press("up"); screen:update()     -- onto the header
    game.press("right"); screen:update()  -- box 2, already full
    game.press("down"); screen:update()   -- back into the grid, still carrying it
    game.press("b"); screen:update()      -- nowhere to put it: box 2 and the party are both full
    T.eq(calls, 0, "a refused placement plays no cry")
    T.eq(#game.save.boxes[2], 20, "and box 2 is undisturbed")
    T.eq(#game.save.party, 6, "and so is the party")
  end

  -- the option, off: nothing plays even on a landing that would otherwise
  -- have played one
  do
    calls = 0
    store.placeCry = false
    local game = fakeGame({ mon("FIXMON_A", 5) })
    local screen = factory.new(game)
    game.press("a"); screen:update()
    game.press("right"); screen:update()
    game.press("a"); screen:update()
    T.eq(calls, 0, "PLACE CRY off plays nothing on a landing that would otherwise cry")
    store.placeCry = true
  end

  Sound.playCry = realPlayCry
end

-- ------- the existing invariants, re-run in the new states
--
-- Nothing drawn may run off the surface or onto the grid, now also in MARK
-- MODE and with the marking window open (PLAN.md "the tests").

do
  local Font2 = require("src.render.Font")
  local realDraw2 = Font2.draw
  local function measureLines(setup)
    local lines = {}
    Font2.draw = function(text, x, y)
      lines[#lines + 1] = { text = text, x = x, y = y, w = Font2.width(text) }
    end
    local g = fakeGame({ mon("FIXMON_A", 50), mon("FIXMON_B", 12) },
      { mon("FIXMON_C", 5) })
    local s = factory.new(g)
    setup(g, s)
    s:draw()
    Font2.draw = realDraw2
    return lines, g, s
  end

  local loader = run.loader
  loader.modOptions = loader.modOptions or {}
  loader.modOptions.gen3_box = loader.modOptions.gen3_box or {}
  local store = loader.modOptions.gen3_box

  for _, grid in ipairs({ "classic", "big" }) do
    store.grid = grid
    local W = grid == "classic" and 160 or 320
    local H = grid == "classic" and 144 or 288
    local gx = grid == "classic" and 10 or 16
    local gy = grid == "classic" and 16 or 32
    local cell = grid == "classic" and 28 or 56
    local gridBottom = gy + 4 * cell

    local function check(lines, label)
      local bad = {}
      for _, l in ipairs(lines) do
        if l.x + l.w > W then
          bad[#bad + 1] = ("%s: %q runs to %d on a %d-wide surface")
            :format(label, l.text, l.x + l.w, W)
        end
        if l.y + 8 > H then
          bad[#bad + 1] = ("%s: %q runs to %d on a %d-tall surface")
            :format(label, l.text, l.y + 8, H)
        end
      end
      T.eq(#bad, 0, table.concat(bad, "; ") ~= "" and table.concat(bad, "; ")
        or (label .. ": every line fits the surface"))
    end

    -- MARK MODE on, cursor over a Pokemon
    local lines = measureLines(function(g, s)
      g.press("up"); s:update()
      g.press("a"); s:update()
      local boxMenu = g.stack:top()
      for i, item in ipairs(boxMenu.items) do
        if item.label == "MARK MODE" then boxMenu.index = i end
      end
      g.press("a"); boxMenu:update()
    end)
    check(lines, grid .. ": MARK MODE on")

    -- the marking window open
    local lines2 = measureLines(function(g, s)
      g.press("up"); s:update()
      g.press("a"); s:update()
      local boxMenu = g.stack:top()
      for i, item in ipairs(boxMenu.items) do
        if item.label == "MARK MODE" then boxMenu.index = i end
      end
      g.press("a"); boxMenu:update()
      g.press("a"); s:update() -- open the window
    end)
    check(lines2, grid .. ": marking window open")

    store.grid = "classic"
  end
end

run.release()
T.finish("gen3_box")
