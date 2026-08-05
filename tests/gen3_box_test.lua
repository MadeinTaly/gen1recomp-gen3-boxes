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

run.release()
T.finish("gen3_box")
