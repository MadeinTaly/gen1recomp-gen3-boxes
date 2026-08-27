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

-- ------- the pc.items discriminator, Gen 2 only
--
-- The same hook fires at two Gold menus (src/ui/gen2/PcMenu.lua, the
-- storage system, and src/ui/gen2/ItemPcMenu.lua, the player's own item
-- PC), and both carry WITHDRAW/DEPOSIT/MAILBOX rows -- so a label is not a
-- safe anchor. Only the storage menu's rows carry id == "changebox".
do
  local gen2Game = { save = { generation = 2 } }
  local storageRows = {
    { id = "withdraw", label = "WITHDRAW <PK><MN>" },
    { id = "deposit", label = "DEPOSIT <PK><MN>" },
    { id = "changebox", label = "CHANGE BOX" },
  }
  local itemRows = {
    { id = "withdraw", label = "WITHDRAW ITEM" },
    { id = "deposit", label = "DEPOSIT ITEM" },
    { id = "toss", label = "TOSS ITEM" },
  }
  local storageOut = Runtime.call("ui.pc.items", passthru, gen2Game, storageRows)
  T.check(has(storageOut, "BOXES"),
    "a storage-menu list (carrying a changebox row) gains the BOXES row")
  local itemOut = Runtime.call("ui.pc.items", passthru, gen2Game, itemRows)
  T.check(not has(itemOut, "BOXES"),
    "an item-PC list (no changebox row) does not")
end

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

-- `data` is the dataset the game hands the screen, and it is Data for every
-- test here but one: the MAIL block runs on a real Gold boot, which is a
-- second SDK load with a fixture dataset of its own (see it below for why).
local function fakeGame(boxMons, partyMons, data)
  local boxes = {}
  for i = 1, 12 do boxes[i] = {} end
  for i, m in ipairs(boxMons or {}) do boxes[1][i] = m end
  local pressed = {}
  return {
    data = data or Data,
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

-- ------- the summary screen id resolves per generation
--
-- Gold's builtin screens carry a Gen2 prefix and a different constructor
-- shape (src/ui/gen2/SummaryMenu.lua:235's opts.mon, vs Gen 1's
-- SummaryMenu.new(game, mon) above).
do
  local gen2Game = fakeGame({ mon("PIKACHU", 5) })
  gen2Game.save.generation = 2
  local gen2Screen = factory.new(gen2Game)
  pushed = nil
  gen2Game.press("start"); gen2Screen:update()
  T.eq(pushed and pushed.id, "Gen2SummaryMenu",
    "on Gen 2, START opens the Gen2-prefixed summary screen")
  T.eq(pushed and pushed.mon and pushed.mon.mon and pushed.mon.mon.species,
    "PIKACHU", "wrapped in opts.mon, the Gen 2 constructor shape")

  -- ...and with the way OUT. Gold's summary never pops itself: every exit
  -- path ends at self:close(), which is `if self.onClose then self.onClose()
  -- end` (src/ui/gen2/SummaryMenu.lua:664-666), so a push without the
  -- callback answers B by doing nothing and the screen stays up forever
  -- (issue #5). Gold's own PC passes one; so does this screen now.
  T.eq(type(pushed and pushed.mon and pushed.mon.onClose), "function",
    "and with an onClose, because Gold's summary cannot close itself")
  local sentinel = { "the summary, on the stack" }
  gen2Game.stack:push(sentinel)
  pushed.mon.onClose()
  T.check(gen2Game.stack:top() ~= sentinel,
    "and that callback is what takes it back off the stack")
end

-- ------- MAIL stays with its own mon, Gen 2 only
--
-- save.mail.party is keyed by SLOT NUMBER (src/core/gen2/Mail.lua), so it
-- has to stay aligned with save.party through every length change this
-- screen makes, not only a removal: grab() shifts the letters behind a
-- departure down (Mail.removeSlot), and every site that grows save.party
-- again has to make room the same way (gen2InsertPartySlot in main.lua) or
-- a later mon lands wearing an earlier one's letter.
--
-- This one runs on a REAL Gold boot rather than on the Gen 1 harness with a
-- Gen 2 save faked onto it, and that is not tidiness: the loader now refuses
-- a mod any `src.*.gen2.*` module while the running game is Gen 1 --
-- "the structs it reads and writes are not this game's, so anything it
-- stores lands on the save in the wrong shape" (src/mods/Loader.lua:121-131,
-- crossGenerationDenial). So a Gen 1 boot cannot reach the letters at all
-- any more, and should not: it has none. The mod is unchanged by that rule
-- -- on Gold the module resolves and the bookkeeping runs -- but the test
-- has to boot the generation it is testing.
do
  local D = T.fixtures.fresh()
  setmetatable(D, { __index = function(_, k)
    local v = Data[k]
    if type(v) == "function" then return v end
    return nil
  end })
  local gen2Run = T.sdk.loadMod(DIR, { data = D, generation = 2 })
  T.eq(#gen2Run.errors, 0, "the Gold boot the MAIL check needs loads clean")
  local gen2Factory = D.screens and D.screens.Gen3Box
  T.check(gen2Factory ~= nil, "and registers the screen on that boot")

  local gen2Game = fakeGame({}, { mon("FIXMON_A", 1), mon("FIXMON_B", 2) }, D)
  gen2Game.save.generation = 2
  gen2Game.save.mail = { party = { [2] = { type = "FLOWER_MAIL", message = "for B" } } }
  local screen = gen2Factory.new(gen2Game)
  gen2Game.press("select"); screen:update() -- cross to the party
  gen2Game.press("a"); screen:update()      -- grab slot 1 (FIXMON_A, no mail)
  gen2Game.press("b"); screen:update()      -- put it straight back
  T.eq(#gen2Game.save.party, 2, "the party is back to two")
  T.eq(gen2Game.save.party[1].species, "FIXMON_B",
    "FIXMON_B is now first -- the array shifted under the letter")
  T.eq(gen2Game.save.mail.party[1] and gen2Game.save.mail.party[1].message, "for B",
    "the letter followed FIXMON_B to its new slot")
  T.check(gen2Game.save.mail.party[2] == nil,
    "and did not stay behind on FIXMON_A's old slot, now FIXMON_A itself")
  gen2Run.release()
end

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

  -- il messaggio di conferma si mangia il tasto successivo: va scartato
  -- prima di riaprire il menu, o la UP finisce nel box di testo
  local function clearSay()
    for _ = 1, 3 do game.press("b"); screen:update() end
  end

  -- guida il selettore come lo guiderebbe un giocatore: giu' fino alla
  -- scena voluta, destra fino alla mano voluta, A per confermare
  local function pickPaper(id, art)
    clearSay()
    choose(openBoxMenu(game, screen), game, "WALLPAPER")
    for _ = 1, 20 do
      if screen.paperPick.id == id then break end
      game.press("down"); screen:update()
    end
    for _ = 2, (art or 1) do game.press("right"); screen:update() end
    game.press("a"); screen:update()
    clearSay()
  end

  -- ------- the wallpaper chooser (1.10.0)
  --
  -- It is no longer a pushed ListMenu: it is drawn by the screen over its
  -- own background, so that the wallpaper under the cursor IS the preview.
  -- That means the assertions here drive the SCREEN's keys, not a menu's.
  local boxMenu = openBoxMenu(game, screen)
  T.check(boxMenu ~= nil and boxMenu.items ~= nil, "the box menu opens")
  choose(boxMenu, game, "WALLPAPER")
  T.check(game.stack:top() == nil,
    "WALLPAPER pushes nothing: the chooser lives inside the screen")
  T.check(screen.paperPick ~= nil, "and the screen is in choosing mode")
  T.eq(screen.paperPick.id, "PLAIN", "starting on the wallpaper this box wears")

  -- down moves to the next place, and the preview follows immediately
  game.press("down"); screen:update()
  T.eq(screen.paperPick.id, "SEA", "DOWN moves to the next scene")
  game.press("a"); screen:update()
  T.check(screen.paperPick == nil, "A closes the chooser")
  local saved = store.boxPapers and store.boxPapers[1]
  T.eq(type(saved) == "table" and saved.id or saved, "SEA",
    "and the box remembers the scene")
  T.eq(type(saved) == "table" and saved.art or 1, 1,
    "with the hand that drew it -- 1 is this mod's own, the default")

  -- LEFT/RIGHT change the ARTIST, and only where there is one to change to
  local boxMenu2 = openBoxMenu(game, screen)
  choose(boxMenu2, game, "WALLPAPER")
  game.press("down"); screen:update()      -- FOREST
  T.eq(screen.paperPick.id, "FOREST", "moved onto a scene with more than one hand")
  local artBefore = screen.paperPick.art
  game.press("right"); screen:update()
  T.check(screen.paperPick.art ~= artBefore,
    "RIGHT picks the next artist for that scene")
  local artName = run.loader.exports.gen3_box.wallpaperArt.FOREST[screen.paperPick.art].by
  T.check(artName ~= "GEN3 BOX",
    "which is somebody else's art (" .. tostring(artName) .. ")")
  game.press("a"); screen:update()
  local saved2 = store.boxPapers[1]
  T.eq(saved2.id, "FOREST", "the box takes the new scene")
  T.check(saved2.art > 1, "and remembers WHOSE, not just which")

  -- START sorteggia scena E mano insieme, e non conferma niente da solo
  do
    clearSay()
    choose(openBoxMenu(game, screen), game, "WALLPAPER")
    local seen = {}
    for _ = 1, 30 do
      game.press("start"); screen:update()
      seen[screen.paperPick.id .. "/" .. screen.paperPick.art] = true
    end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    T.check(n > 1, "START mescola: trenta pressioni danno piu' di una scelta")
    local before = store.boxPapers[1]
    game.press("b"); screen:update()
    T.eq(store.boxPapers[1].id, before.id,
      "e non salva nulla da solo: serve comunque la A")
  end

  -- SELECT ALTERNA: la prima volta aggiunge ai preferiti, la seconda toglie.
  -- FAVOURITE e' una categoria che pesca fra quelli, quindi con l'insieme
  -- vuoto non ha niente da mostrare e con l'insieme pieno mostra uno dei suoi.
  do
    clearSay()
    choose(openBoxMenu(game, screen), game, "WALLPAPER")
    for _ = 1, 20 do
      if screen.paperPick.id == "CITY" then break end
      game.press("down"); screen:update()
    end
    game.press("select"); screen:update()
    T.eq(#(store.favePapers or {}), 1, "SELECT aggiunge ai preferiti")
    T.eq(store.favePapers[1].id, "CITY", "e aggiunge quello che stai guardando")
    game.press("select"); screen:update()
    T.eq(#store.favePapers, 0, "SELECT di nuovo sullo stesso lo toglie")
    game.press("select"); screen:update()
    T.eq(#store.favePapers, 1, "e ancora lo rimette: e' un interruttore")
    game.press("b"); screen:update()
    clearSay()

    -- una box su FAVOURITE indossa uno dei preferiti
    store.boxPapers[1] = { id = "FAVE", art = 1 }
    T.eq(screen.paperIdOf(1), "CITY",
      "con un solo preferito, FAVOURITE mostra quello")
    T.check(screen:sgbPalettes(game)[1].colors == false,
      "e la superficie sotto una scena esce dal rimappaggio")

    -- svuotando l'insieme non puo' inventarsi niente: torna al neutro
    store.favePapers = {}
    local zones = screen:sgbPalettes(game)
    T.check(zones[1].colors == PaletteFX.GRAYS,
      "senza preferiti FAVOURITE non finge: resta PLAIN")
    store.boxPapers[1] = { id = "NIGHT", art = 1 }
  end

  -- B leaves everything as it was
  clearSay()
  local before = store.boxPapers[1]
  local boxMenu3 = openBoxMenu(game, screen)
  choose(boxMenu3, game, "WALLPAPER")
  game.press("down"); screen:update()
  game.press("b"); screen:update()
  T.check(screen.paperPick == nil, "B closes it")
  T.eq(store.boxPapers[1].id, before.id, "and changes nothing")

  -- a save written by 1.9.x holds a bare string: it has to keep working,
  -- and it means "that scene, drawn here"
  store.boxPapers[1] = "SEA"
  T.eq(screen.paperIdOf and screen.paperIdOf(1) or "SEA", "SEA",
    "a legacy string save still names its scene")
  store.boxPapers[1] = { id = "SEA", art = 1 }

  local zonesAfter = screen:sgbPalettes(game)
  -- A scene is not four shades waiting for a palette: it is painted in its
  -- own RGB, and an artist's strip arrives coloured. Remapping either one
  -- through the shade ramp a second time is what made BIG grey while the
  -- Pokemon on top of it stayed in colour. So the surface under a wallpaper
  -- opts OUT (colors == false) and shows what was drawn.
  T.check(zonesAfter[1].colors == false,
    "SEA takes the base zone out of the shade-remap")
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

  -- NIGHT is still the one scene that runs the ramp backwards: its
  -- lightest-mapped entry is the DARKEST colour and its darkest-mapped entry
  -- is the lightest, which is what makes it a real dark mode rather than a
  -- blue tint. The exact values are the theme's own now that every wallpaper
  -- carries a scene palette, so what is asserted is the ORDER.
  pickPaper("NIGHT")
  local night
  for _, w in ipairs(run.loader.exports.gen3_box.wallpapers) do
    if w.id == "NIGHT" then night = w.palette end
  end
  local function luma(c) return 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3] end
  T.check(luma(night[1]) < 60, "NIGHT's lightest-mapped shade is dark")
  T.check(luma(night[4]) > 200, "and its darkest-mapped shade is light")
  -- ------- l'arte di qualcun altro non deve mai far cadere il frame
  --
  -- Gli stili con immagine passano da Assets.image, che su un boot senza
  -- quell'asset risponde nil: il disegno deve degradare al pattern, non
  -- morire dentro il draw.
  do
    local art = run.loader.exports.gen3_box.wallpaperArt.FOREST
    local withImage
    for i, a in ipairs(art) do if a.layers or a.image then withImage = i end end
    T.check(withImage ~= nil, "FOREST ha almeno uno stile a immagine")
    store.boxPapers[1] = { id = "FOREST", art = withImage }
    local ok = pcall(function() screen:draw() end)
    T.check(ok, "un wallpaper a immagine si disegna senza far cadere il frame")
    store.boxPapers[1] = { id = "NIGHT", art = 1 }
  end

  T.check(luma(night[1]) < luma(night[4]),
    "so the ramp really is reversed, which is the whole point of NIGHT")

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

-- ------- overworld sprites from Wilds of Kanto (the seam)
--
-- No graphics context, and that mod is never actually installed in CI, so
-- this stubs the seam rather than the pixels: a fake mod record dropped
-- straight into loader.mods/loader.exports is what mod.find(id) itself
-- reads (src/mods/Loader.lua:1002), so it stands in for the other mod
-- exactly the way isActive() and the exports table would see a real one.
-- screen.spriteToDraw is exposed for the same reason self.picScale is:
-- checking the seam does not need love.graphics.draw to exist.

do
  local loader = run.loader
  loader.modOptions = loader.modOptions or {}
  loader.modOptions.gen3_box = loader.modOptions.gen3_box or {}
  local store = loader.modOptions.gen3_box

  local OW_ID = "overworld_wild_spawns"
  local anySpecies = next(Data.pokemon)

  local function installOw(resolveFn)
    loader.mods[OW_ID] = { enabled = true, failed = false,
                            manifest = { version = "1.14.0" } }
    loader.exports[OW_ID] = {
      spriteProviders = { resolve = function(_, style, speciesId, variant, game)
        return resolveFn(style, speciesId, variant, game)
      end },
    }
  end
  local function removeOw()
    loader.mods[OW_ID] = nil
    loader.exports[OW_ID] = nil
  end

  -- the option off: the seam is never consulted at all, even with a
  -- perfectly good handle sitting there
  do
    store.owSprites = false
    local calls = 0
    installOw(function()
      calls = calls + 1
      return { def = { image = "ow.png", frames = 1 }, providerId = "gold" }
    end)
    store.grid = "classic"
    local game = fakeGame({ mon(anySpecies, 5) })
    local screen = factory.new(game)
    local chosen = screen.spriteToDraw(game.save.boxes[1][1])
    T.eq(calls, 0, "OW SPRITES off never calls resolve")
    T.eq(chosen and chosen.kind, "battle",
      "and the screen draws exactly what it drew before")
    removeOw()
  end

  -- no handle at all (the option on, the other mod simply absent): draws
  -- exactly what it drew before -- every existing invariant still holds,
  -- because nothing here changed the picture path
  do
    store.owSprites = true
    store.grid = "classic"
    local game = fakeGame({ mon(anySpecies, 5) })
    local screen = factory.new(game)
    local chosen = screen.spriteToDraw(game.save.boxes[1][1])
    T.eq(chosen and chosen.kind, "battle",
      "no handle falls back to the battle picture")
  end

  -- a handle with a real def: CLASSIC draws it, BIG does not
  do
    store.owSprites = true
    installOw(function(style, speciesId)
      T.eq(style, nil, "style is passed through nil -- the player's own Sprite Style")
      T.eq(speciesId, anySpecies, "and the species id is the mon's own")
      return { def = { image = "ow.png", frames = 3 }, providerId = "gold" }
    end)

    store.grid = "classic"
    local game = fakeGame({ mon(anySpecies, 5) })
    local screen = factory.new(game)
    local chosen = screen.spriteToDraw(game.save.boxes[1][1])
    T.eq(chosen and chosen.kind, "ow", "CLASSIC draws the overworld sprite")

    store.grid = "big"
    local gameBig = fakeGame({ mon(anySpecies, 5) })
    local screenBig = factory.new(gameBig)
    local chosenBig = screenBig.spriteToDraw(gameBig.save.boxes[1][1])
    T.eq(chosenBig and chosenBig.kind, "battle",
      "BIG keeps the battle picture even with a good handle -- a 16px sprite "
      .. "would have to be blown up to fill a 56px cell")

    removeOw()
    store.grid = "classic"
  end

  -- ------- and whether that picture is already coloured (issue #4)
  --
  -- The cell wears its species' four-colour SGB palette, and the renderer
  -- reads the pixels under it as four DMG greys. Art that is already
  -- coloured has to say so or it comes out in somebody else's palette, so
  -- the flag travels with the picture from here to the draw. That mod's own
  -- convention is that UNSET means full colour
  -- (lib/sprite_providers.lua:119-125), which is what the defs below check.
  do
    store.owSprites = true
    store.grid = "classic"

    installOw(function()
      return { def = { image = "ow.png", frames = 1 }, providerId = "gold" }
    end)
    local game = fakeGame({ mon(anySpecies, 5) })
    local screen = factory.new(game)
    local chosen = screen.spriteToDraw(game.save.boxes[1][1])
    T.eq(chosen and chosen.kind, "ow", "the overworld sprite is what is drawn")
    T.check(chosen and chosen.trueColor == true,
      "and an overworld sprite with no flag is full colour, that mod's own default")
    removeOw()

    -- ...and a luminance sheet, which that mod serves with the flag OFF,
    -- is four shades and belongs under the remap like a battle pic
    installOw(function()
      return { def = { image = "ow.png", frames = 1, trueColor = false },
               providerId = "gold" }
    end)
    local lumaGame = fakeGame({ mon(anySpecies, 5) })
    local lumaScreen = factory.new(lumaGame)
    local luma = lumaScreen.spriteToDraw(lumaGame.save.boxes[1][1])
    T.check(luma and luma.trueColor == false,
      "a sprite that says trueColor = false keeps the shade remap")
    removeOw()
  end

  -- The battle picture carries the same word, and it is Sprites.path's
  -- SECOND return value -- the one 1.9.2 dropped on the floor, which is the
  -- whole of issue #4. A Crystal-sprites mod sets it on the record or on the
  -- ctx; vanilla art never does.
  do
    store.owSprites = false
    store.grid = "classic"
    local def = Data.pokemon[anySpecies]
    local realFlag = def.trueColor

    def.trueColor = nil
    local plainGame = fakeGame({ mon(anySpecies, 5) })
    local plain = factory.new(plainGame)
    local chosenPlain = plain.spriteToDraw(plainGame.save.boxes[1][1])
    T.eq(chosenPlain and chosenPlain.kind, "battle", "vanilla art is a battle pic")
    T.check(chosenPlain and not chosenPlain.trueColor,
      "and carries no trueColor, so the SGB remap it was drawn for still runs")

    def.trueColor = true
    local colourGame = fakeGame({ mon(anySpecies, 5) })
    local colour = factory.new(colourGame)
    local chosenColour = colour.spriteToDraw(colourGame.save.boxes[1][1])
    T.check(chosenColour and chosenColour.trueColor == true,
      "a record that says its art is already coloured says so all the way to the draw")

    def.trueColor = realFlag
  end

  -- a black-fallback result is treated as a miss, the same as no handle
  do
    store.owSprites = true
    installOw(function()
      return { def = nil, providerId = "black", error = "all providers failed" }
    end)
    store.grid = "classic"
    local game = fakeGame({ mon(anySpecies, 5) })
    local screen = factory.new(game)
    local chosen = screen.spriteToDraw(game.save.boxes[1][1])
    T.eq(chosen and chosen.kind, "battle",
      "a black-fallback result falls back to the battle picture")
    removeOw()
  end

  -- resolve throwing is caught, not propagated, and still falls back
  do
    store.owSprites = true
    installOw(function() error("boom") end)
    store.grid = "classic"
    local game = fakeGame({ mon(anySpecies, 5) })
    local screen = factory.new(game)
    local ok, chosen = pcall(screen.spriteToDraw, game.save.boxes[1][1])
    T.check(ok, "a throwing resolve does not propagate out of spriteToDraw")
    T.eq(ok and chosen and chosen.kind, "battle",
      "and the cell falls back to the battle picture rather than staying blank")
    removeOw()
  end

  -- Cached per MON for the life of the screen -- not per species (issue #2),
  -- and not per cell or per draw either. resolve() walks a provider chain, so
  -- calling it twenty times a frame is not free; but caching it by species is
  -- what made a shiny and an ordinary one of the same species draw the same
  -- picture, whichever of the two was resolved first. So: one call per mon,
  -- however many times that mon is drawn.
  do
    store.owSprites = true
    local calls = 0
    installOw(function()
      calls = calls + 1
      return { def = { image = "ow.png", frames = 1 }, providerId = "gold" }
    end)
    store.grid = "classic"
    local game = fakeGame({ mon(anySpecies, 5), mon(anySpecies, 9) })
    local screen = factory.new(game)
    screen.spriteToDraw(game.save.boxes[1][1])
    screen.spriteToDraw(game.save.boxes[1][1])
    T.eq(calls, 1, "drawing the same mon twice resolves once")
    screen.spriteToDraw(game.save.boxes[1][2])
    T.eq(calls, 2,
      "a SECOND mon of the same species resolves on its own -- one shiny, "
      .. "one not, must be able to differ (issue #2)")
    removeOw()
  end

  store.owSprites = false
  store.grid = "classic"
end

-- ------- the party-menu resolver is preferred over spriteProviders
--
-- Wilds of Kanto draws the sprites the player can already see by patching
-- PartyMenu.drawIcon and resolving through its follower sprite service
-- (lib/follower/sprite_service.lua:222,384). spriteProviders is the tidier
-- seam; the party resolver is the one with a screenshot behind it. So it is
-- asked first, and these assert that rather than trusting it.

do
  local loader = run.loader
  local store = loader.modOptions.gen3_box
  local OW_ID = "overworld_wild_spawns"
  local anySpecies = next(Data.pokemon)

  local function install(partyFn, providerFn)
    loader.mods[OW_ID] = { enabled = true, failed = false,
                            manifest = { version = "1.14.0" } }
    loader.exports[OW_ID] = {
      follower = { spriteService = {
        resolvePartyIconDef = function(_, m, g) return partyFn(m, g) end,
      } },
      spriteProviders = providerFn and { resolve = function(_, st, id, v, g)
        return providerFn(st, id, v, g)
      end } or nil,
    }
  end
  local function remove()
    loader.mods[OW_ID] = nil
    loader.exports[OW_ID] = nil
  end

  store.owSprites = true
  store.grid = "classic"

  -- both available: the party resolver answers and the provider is never
  -- reached
  do
    local partyCalls, providerCalls = 0, 0
    install(function()
      partyCalls = partyCalls + 1
      return { image = "party.png", frames = 1 }
    end, function()
      providerCalls = providerCalls + 1
      return { def = { image = "provider.png", frames = 1 }, providerId = "gold" }
    end)
    local game = fakeGame({ mon(anySpecies, 5) })
    local screen = factory.new(game)
    local chosen = screen.spriteToDraw(game.save.boxes[1][1])
    T.eq(chosen and chosen.kind, "ow", "the party resolver's sprite is drawn")
    T.eq(partyCalls, 1, "the party resolver is asked")
    T.eq(providerCalls, 0, "and spriteProviders is not reached behind it")
    remove()
  end

  -- it is handed the Pokemon itself, not a species id: the resolver reads
  -- form and shininess off the mon
  do
    local got
    install(function(m) got = m; return { image = "party.png", frames = 1 } end)
    local game = fakeGame({ mon(anySpecies, 5) })
    local screen = factory.new(game)
    screen.spriteToDraw(game.save.boxes[1][1])
    T.eq(got, game.save.boxes[1][1], "the resolver is handed the mon itself")
    remove()
  end

  -- the party resolver missing, or answering with nothing, falls through to
  -- spriteProviders rather than giving up on the feature
  do
    local providerCalls = 0
    install(function() return nil end, function()
      providerCalls = providerCalls + 1
      return { def = { image = "provider.png", frames = 1 }, providerId = "gold" }
    end)
    local game = fakeGame({ mon(anySpecies, 5) })
    local screen = factory.new(game)
    local chosen = screen.spriteToDraw(game.save.boxes[1][1])
    T.eq(chosen and chosen.kind, "ow", "a party-resolver miss still reaches a sprite")
    T.eq(providerCalls, 1, "by falling through to spriteProviders")
    remove()
  end

  -- a party resolver that throws is caught, exactly like the provider one
  do
    install(function() error("boom") end)
    local game = fakeGame({ mon(anySpecies, 5) })
    local screen = factory.new(game)
    local chosen = screen.spriteToDraw(game.save.boxes[1][1])
    T.eq(chosen and chosen.kind, "battle",
      "a throwing party resolver falls back to the battle picture")
    remove()
  end

  store.owSprites = false
  store.grid = "classic"
end

-- ------- the MENU button, and saying where the menu is
--
-- 1.6.0's whole surface hung off a move nothing on screen mentioned: the
-- footer hint that named the header only drew on an EMPTY cell, and the
-- cell under the cursor is occupied nearly all the time. These assert the
-- two things that fix it -- a button that is always drawn, and one notice
-- on the way in -- and that the button never costs the title its text.

do
  local realDraw2, realBox2 = Font.draw, Font.drawBox
  local lines = {}
  Font.draw = function(text, x, y) lines[#lines + 1] = { text = text, x = x, y = y } end
  Font.drawBox = function() end

  local function draw(setup)
    lines = {}
    local g = fakeGame({ mon("PIKACHU", 100) }, { mon("CHARIZARD", 100) })
    local s = factory.new(g)
    if setup then setup(g, s) end
    s:draw()
    return lines
  end

  local function find(set, text)
    for _, l in ipairs(set) do if l.text == text then return l end end
    return nil
  end

  local boxLines = draw()
  T.check(find(boxLines, "MENU") ~= nil,
    "the box pane draws a MENU button without being asked")

  local partyLines = draw(function(g, s) g.press("select"); s:update() end)
  T.check(find(partyLines, "MENU") == nil,
    "the party pane draws none -- there is no header there to open")

  -- the notice is on the first frame and gone once it has aged out
  T.check(find(boxLines, "UP: BOX MENU") ~= nil,
    "opening the screen says where the menu is")
  local aged = draw(function(_, s) s.noticeAt = -10 end)
  T.check(find(aged, "UP: BOX MENU") == nil,
    "and stops saying it, rather than sitting on the footer forever")

  -- an eight-glyph name plus " 20/20" is wider than CLASSIC has left once
  -- the button has its corner: the title gives way, the button does not
  local long = draw(function(g)
    g.save.currentBox = 12
    for i = 1, 20 do g.save.boxes[12][i] = mon("NIDORANDER", 100) end
  end)
  local button = find(long, "MENU")
  T.check(button ~= nil, "a full box with a long title still draws the button")
  local title = long[1]
  T.check(title.x + Font.width(title.text) <= button.x,
    ("the title stops before the button (title ends %d, button at %d)")
      :format(title.x + Font.width(title.text), button.x))

  Font.draw, Font.drawBox = realDraw2, realBox2
end

run.release()

-- ------- runs on Gen 2 too
--
-- Runtime is process-wide, so a second load has to come after this file's
-- first one is released -- and everything above depends on that first
-- run's own registrations (Data.screens.Gen3Box, the hooks it drives), so
-- this sits at the very end rather than beside the load at the top.
--
-- A load with no `data =` would inherit from the `Data` singleton through
-- __index -- Data:load() already ran at the top of this file -- so
-- namespaces the fresh fixture does not carry (tokens, statuses, ...) would
-- leak through and the loader would re-register them. T.fixtures.fresh()
-- is the real fresh dataset; only Data's METHODS are borrowed off it,
-- never its already-loaded tables.
--
-- The SDK harness takes the generation directly and runs the real loader --
-- same validate, same topological sort, same merge
-- (docs/preparing-your-mod-for-gen2.md "Testing"). A gate skip is
-- deliberately not an error, so the error count alone is not enough: state
-- has to be "loaded" for this to mean the entry chunk actually ran, not
-- merely that nothing threw.
do
  local D = T.fixtures.fresh()
  setmetatable(D, { __index = function(_, k)
    local v = Data[k]
    if type(v) == "function" then return v end
    return nil
  end })
  local gen2Run = T.sdk.loadMod(DIR, { data = D, generation = 2 })
  T.eq(gen2Run.mod and gen2Run.mod.state, "loaded",
    "runs on gen 2: " .. tostring(gen2Run.mod and gen2Run.mod.skipReason))
  T.eq(#gen2Run.errors, 0, "and loads with no boot errors")
  gen2Run.release()
end

-- ------- issue #2: a shiny and an ordinary one of the same species
--
-- Reported against 1.8.0: two Pokemon of the same species, one shiny and one
-- not, drew the SAME picture -- both shiny or both ordinary, depending on
-- which was resolved first.
--
-- The cause was that this screen asked the SPECIES for its art (the record's
-- own `spriteFront`) and never the Pokemon. A species has one record and one
-- path, so there was nothing in the question that could tell two of them
-- apart, and a mod supplying shiny art was never consulted at all.
--
-- src/pokemon/Sprites.lua is the seam for this: Sprites.path raises
-- `pokemon.sprite` with the live mon in its ctx, which its own header calls
-- "per-instance skins". So what is asserted here is the QUESTION, not the
-- picture -- this suite has no shiny art to compare against, and the answer
-- belongs to whichever mod supplies it. Sprites.path is swapped on the module
-- table (which is what the screen indexes on every call) to record what it is
-- asked.
do
  local Sprites = require("src.pokemon.Sprites")
  local realPath = Sprites.path
  local asked = {}
  Sprites.path = function(data, species, side, opts)
    asked[#asked + 1] = { species = species, mon = opts and opts.mon }
    -- Answer per INSTANCE, the way a shiny-art mod answers the hook.
    if opts and opts.mon and opts.mon.shiny then
      return "shiny/" .. tostring(species) .. ".png", false
    end
    return realPath(data, species, side, opts)
  end

  local loader = run.loader
  loader.modOptions = loader.modOptions or {}
  loader.modOptions.gen3_box = loader.modOptions.gen3_box or {}
  local store = loader.modOptions.gen3_box
  store.owSprites = false
  store.grid = "classic"
  local anySpecies = next(Data.pokemon)
  local game = fakeGame({ mon(anySpecies, 5), mon(anySpecies, 5) })
  game.save.boxes[1][2].shiny = true
  local screen = factory.new(game)
  screen.spriteToDraw(game.save.boxes[1][1])
  screen.spriteToDraw(game.save.boxes[1][2])

  Sprites.path = realPath

  T.eq(#asked, 2,
    "each Pokemon is asked about on its own, not once for the species")
  T.check(asked[1].mon ~= nil and asked[2].mon ~= nil,
    "the live mon is handed to the art seam (issue #2: it never was)")
  T.check(asked[1].mon ~= asked[2].mon,
    "and the two questions carry the two DIFFERENT mons")
  T.check(asked[2].mon.shiny == true,
    "the shiny one arrives as itself, so a shiny-art mod can answer for it")
  T.eq(asked[1].species, anySpecies, "the species is still passed alongside")
end

-- ------- ...and art this screen cannot draw is not "no art"
--
-- The first cut of the issue #2 fix regressed the whole grid to empty cells.
-- A mod that renders a Pokemon some other way -- voxels, 3D, its own atlas --
-- legitimately answers `pokemon.sprite` with a path that is not a plain 2D
-- image, Assets.image then loads nothing, and treating that as "no picture"
-- draws an empty box. That is worse than the bug being fixed: a wrong picture
-- at least says which Pokemon is in the slot.
--
-- Both seams are stubbed here rather than only the first, because the real
-- Assets.image answers for any path in a headless run -- so a test that only
-- swapped Sprites.path could not tell a fallback from its absence, and passed
-- either way. Loading is what has to fail for this to mean anything.
do
  local Sprites = require("src.pokemon.Sprites")
  local Assets = require("src.render.Assets")
  local realPath, realImage = Sprites.path, Assets.image
  local VOXEL = "voxel://no-such-2d-image"
  local vanillaImage = { fake = "the species record's own PNG" }
  local askedFor = {}

  Sprites.path = function() return VOXEL, false end
  Assets.image = function(path)
    askedFor[#askedFor + 1] = path
    -- What a voxel answer looks like to a 2D image cache: nothing loadable.
    if path == VOXEL then return nil end
    return vanillaImage
  end

  local loader = run.loader
  loader.modOptions = loader.modOptions or {}
  loader.modOptions.gen3_box = loader.modOptions.gen3_box or {}
  local store = loader.modOptions.gen3_box
  store.owSprites = false
  store.grid = "classic"
  local anySpecies = next(Data.pokemon)
  local game = fakeGame({ mon(anySpecies, 5) })
  local screen = factory.new(game)
  local chosen = screen.spriteToDraw(game.save.boxes[1][1])

  Sprites.path, Assets.image = realPath, realImage

  T.eq(askedFor[1], VOXEL, "the per-instance answer is tried first")
  T.check(#askedFor >= 2,
    "and when it loads nothing, a second candidate is tried at all")
  T.check(chosen ~= nil,
    "art the screen cannot draw falls back to the species record, "
    .. "rather than leaving the cell empty")
  T.eq(chosen and chosen.kind, "battle", "and it is the battle picture")
  T.eq(chosen and chosen.img, vanillaImage, "drawn from the species record")
end

-- ------- the wallpaper moves, and the cells sit on a shelf
--
-- Two things are asserted through love.graphics itself, because both are
-- purely about what gets drawn and there is nothing else to ask.
--
-- 1. ANIMATE on: the same box drawn at two different ticks does not draw the
--    same geometry. Off: it draws exactly the same geometry, which is the
--    promise that the option gives the still wallpaper back pixel for pixel.
-- 2. Every cell is washed with 15% white before its outline -- the thing that
--    makes the grid read as a shelf of slots rather than as pictures lying on
--    a pattern.
do
  local loader = run.loader
  loader.modOptions = loader.modOptions or {}
  loader.modOptions.gen3_box = loader.modOptions.gen3_box or {}
  local opts = loader.modOptions.gen3_box
  opts.grid = "classic"
  opts.owSprites = false

  loader.modSave = loader.modSave or {}
  loader.modSave.gen3_box = loader.modSave.gen3_box or {}
  -- SEA: 1.10.0 draws its swell with RECTANGLES rather than hairlines (a
  -- one-pixel line on this surface read as ruled paper), so the recorder
  -- below watches rectangle positions as well as lines. What is asserted is
  -- unchanged: the scene is somewhere else forty ticks later.
  loader.modSave.gen3_box.boxPapers = { [1] = { id = "SEA", art = 1 } }

  local G = love.graphics
  local realLine, realRect, realColor = G.line, G.rectangle, G.setColor
  local lines, washes, colour = {}, 0, { 0, 0, 0, 1 }
  local fullScreenFills = 0
  G.setColor = function(r, g, b, a) colour = { r, g, b, a or 1 }; return realColor(r, g, b, a) end
  G.line = function(...) lines[#lines + 1] = table.concat({ ... }, ",") end
  G.rectangle = function(mode, x, y, w, h)
    -- position, not just count: a wallpaper that moves draws the same
    -- shapes somewhere else, and that is exactly what has to be detected
    if #lines < 4000 then
      lines[#lines + 1] = "R" .. tostring(x) .. "," .. tostring(y)
    end
    -- The wallpaper's ground colour: the WHOLE surface, in a scene colour
    -- rather than white. This is the layering the box screen is built on --
    -- the scene covers everything and the slots are laid on top of it -- and
    -- 1.9.0-beta.1 got it inside out, painting the pattern only inside the
    -- grid so the box read as a panel on a white page.
    if mode == "fill" and x == 0 and y == 0 and w == 160 and h == 144
        and not (colour[1] == 1 and colour[2] == 1 and colour[3] == 1) then
      fullScreenFills = fullScreenFills + 1
    end
    -- A filled square in white at 15%: the cell wash, and nothing else in
    -- this screen draws that.
    -- A filled white square at the slot alpha: the cell wash. Nothing else
    -- on this screen draws a white square at that opacity.
    if mode == "fill" and colour[1] == 1 and colour[2] == 1 and colour[3] == 1
        and colour[4] and math.abs(colour[4] - 0.40) < 0.001 and w == h then
      washes = washes + 1
    end
  end

  local function frame(screen, ticks)
    for _ = 1, ticks do screen:update() end
    lines = {}
    washes = 0
    fullScreenFills = 0
    screen:draw()
    return table.concat(lines, ";"), washes
  end

  local game = fakeGame({})
  game.save.currentBox = 1
  local screen = factory.new(game)
  opts.slots = "40"

  opts.animate = true
  local early = frame(screen, 1)
  local later = frame(screen, 40)
  T.check(early ~= later,
    "ANIMATE on: the wallpaper is somewhere else forty ticks later")

  opts.animate = false
  local stillA = frame(screen, 1)
  local stillB = frame(screen, 40)
  T.eq(stillA, stillB,
    "ANIMATE off: the same wallpaper, tick after tick, pinned at phase zero")

  opts.animate = true
  frame(screen, 1)
  T.check(fullScreenFills >= 1,
    "the wallpaper covers the whole screen, not just the grid rect")

  local _, cellWashes = frame(screen, 1)
  T.eq(cellWashes, 20,
    "every cell in the box is a pale slot laid over the wallpaper")

  -- ------- BIG draws the same scene, twice the size
  --
  -- Every pattern is written in literal pixels of a 160x144 screen: ten
  -- roofs eighteen apart is a street across THAT screen. Handed BIG's
  -- 320x288 canvas they painted a town in one corner and left the rest
  -- white, which is what a player photographed. The scene has to arrive
  -- scaled -- not stretched, not re-derived -- so both halves are asserted:
  -- the transform is applied, AND the scene is still composed for 160x144
  -- underneath it.
  do
    local realScale = G.scale
    local factors = {}
    G.scale = function(x, y) factors[#factors + 1] = { x, y }; return realScale(x, y) end
    opts.grid = "big"
    local bigScreen = factory.new(game)
    frame(bigScreen, 1)
    opts.grid = "classic"
    G.scale = realScale

    local doubled = false
    for _, f in ipairs(factors) do
      if f[1] == 2 and f[2] == 2 then doubled = true end
    end
    T.check(doubled, "BIG draws the wallpaper at scale two")
    T.check(fullScreenFills >= 1,
      "and the scene is still composed for 160x144, so it fills that canvas "
      .. "instead of sitting in a corner of it")
  end

  -- SLOTS is a ladder, and both of its ends have to mean what they say.
  -- CLEAR draws no slot at all -- the wallpaper straight through -- and a
  -- heavier setting draws the same twenty squares at its own opacity.
  local function washesAt(setting, alpha)
    opts.slots = setting
    local found = 0
    local realRect2 = G.rectangle
    G.rectangle = function(mode, x, y, w, h)
      if mode == "fill" and colour[1] == 1 and colour[2] == 1 and colour[3] == 1
          and colour[4] and math.abs(colour[4] - alpha) < 0.001 and w == h then
        found = found + 1
      end
    end
    screen:update()
    screen:draw()
    G.rectangle = realRect2
    return found
  end

  T.eq(washesAt("80", 0.80), 20, "SLOTS 80% draws every slot at 80%")
  T.eq(washesAt("25", 0.25), 20, "SLOTS 25% draws every slot at 25%")
  local anyAtAll = 0
  opts.slots = "0"
  G.rectangle = function(mode, x, y, w, h)
    if mode == "fill" and colour[1] == 1 and colour[2] == 1 and colour[3] == 1
        and w == h and w == 28 then
      anyAtAll = anyAtAll + 1
    end
  end
  screen:update(); screen:draw()
  T.eq(anyAtAll, 0, "SLOTS CLEAR draws no slot at all: the scene, straight through")
  opts.slots = "40"

  G.line, G.rectangle, G.setColor = realLine, realRect, realColor
end

-- ------- the follower is told when the party changes
--
-- Reported: deposit the shiny that is following you, withdraw an ordinary
-- Pokemon, close the screen, and the follower behind you is still the shiny
-- one until you change maps or enter a Pokemon Centre.
--
-- The party really did change; what was missing is that anything was SAID
-- about it. The follower is spawned once and rebuilt on
-- PikachuFollower.onMapEntered, which is why walking through a door fixes
-- it -- so this screen has to ask for that rebuild on the way out.
--
-- Asserted through the engine module itself, and both ways round: a screen
-- that changed nothing must NOT respawn the follower, or every visit to the
-- boxes would twitch the thing behind you for no reason.
do
  -- The mod requires this module through the loader's own require shim, so
  -- swapping a field on the table this file gets back is not necessarily
  -- swapping the table the mod sees. The module entry itself is replaced
  -- instead, which every route to it resolves through.
  -- BOTH names, because which one the mod's require resolves to depends on
  -- the boot: on a Gen 2 boot the loader's shim answers
  -- `src.world.PikachuFollower` with the adapter over
  -- `src.world.gen2.Follower` ("gen2 facade: src.world.PikachuFollower ->
  -- src.world.gen2.Follower" in the log), and this suite loads the mod on
  -- both generations before it gets here. Stubbing only the Gen 1 name
  -- passed locally and failed in CI, which is the test being fragile rather
  -- than the mod being wrong.
  local NAMES = { "src.world.PikachuFollower", "src.world.gen2.Follower" }
  local realModules = {}
  local calls, lastViaMapLoad = 0, "unset"
  local stub = {
    onMapEntered = function(_game, _ow, _opts, viaMapLoad)
      calls = calls + 1
      lastViaMapLoad = viaMapLoad
    end,
  }
  for _, name in ipairs(NAMES) do
    realModules[name] = package.loaded[name]
    package.loaded[name] = stub
  end

  local anySpecies = next(Data.pokemon)

  -- 1. Opened and closed without touching anything.
  do
    local game = fakeGame({ mon(anySpecies, 5) }, { mon(anySpecies, 9) })
    game.overworld = { fake = "the overworld" }
    local screen = factory.new(game)
    calls = 0
    screen:exit()
    T.eq(calls, 0, "an untouched party does not respawn the follower")
  end

  -- 2. A withdrawal: box -> party, which is exactly the reported flow.
  do
    local game = fakeGame({ mon(anySpecies, 5) }, { mon(anySpecies, 9) })
    game.overworld = { fake = "the overworld" }
    local screen = factory.new(game)
    calls = 0
    -- The mon that was in the box is now the party's, the way a withdrawal
    -- leaves it.
    table.insert(game.save.party, game.save.boxes[1][1])
    table.remove(game.save.boxes[1], 1)
    screen:exit()
    T.eq(calls, 1, "a party that changed respawns the follower once")
    T.eq(lastViaMapLoad, false,
      "and as a MID-MAP respawn -- behind the player, not under him")
  end

  -- 3. Gold spells the overworld differently, and the adapter serves the
  --    same module name there, so the one call has to cover both.
  do
    local game = fakeGame({ mon(anySpecies, 5) }, { mon(anySpecies, 9) })
    game.overworld = nil
    game.world = { fake = "Gold's world" }
    game.save.generation = 2
    local screen = factory.new(game)
    calls = 0
    table.insert(game.save.party, game.save.boxes[1][1])
    table.remove(game.save.boxes[1], 1)
    screen:exit()
    T.eq(calls, 1, "on Gold the world is found under its own name")
  end

  for _, name in ipairs(NAMES) do package.loaded[name] = realModules[name] end
end

-- ------- ...and Wilds of Kanto's follower, which is not the engine's
--
-- 1.9.1 respawned the ENGINE's follower and the report stayed open. That mod
-- does not ride PikachuFollower at all: it keeps its own trailing entities
-- and designates the follower through save data rather than party order, so
-- the engine respawn rebuilt something that was never the thing on screen.
--
-- Its exported syncAll(game, ow) is the seam that does what a map change
-- does, which is exactly what the reporter observed fixes it. So: when that
-- mod is installed and the party changed, it must be called.
do
  local loaderRef = run.loader
  loaderRef.mods = loaderRef.mods or {}
  loaderRef.exports = loaderRef.exports or {}
  local OW = "overworld_wild_spawns"

  local syncCalls, sawGame, sawOw = 0, nil, nil
  loaderRef.mods[OW] = { enabled = true, failed = false,
                          manifest = { version = "2.1.8" } }
  loaderRef.exports[OW] = {
    syncAll = function(g, ow)
      syncCalls = syncCalls + 1
      sawGame, sawOw = g, ow
    end,
  }

  local anySpecies = next(Data.pokemon)

  -- the party changed: both followers are told
  do
    local game = fakeGame({ mon(anySpecies, 5) }, { mon(anySpecies, 9) })
    game.overworld = { fake = "the overworld" }
    local screen = factory.new(game)
    syncCalls = 0
    table.insert(game.save.party, game.save.boxes[1][1])
    table.remove(game.save.boxes[1], 1)
    screen:exit()
    T.eq(syncCalls, 1, "Wilds of Kanto's own syncAll is called on the way out")
    T.check(sawGame == game, "with the live game")
    T.check(sawOw == game.overworld, "and the live overworld")
  end

  -- nothing changed: nothing is disturbed
  do
    local game = fakeGame({ mon(anySpecies, 5) }, { mon(anySpecies, 9) })
    game.overworld = { fake = "the overworld" }
    local screen = factory.new(game)
    syncCalls = 0
    screen:exit()
    T.eq(syncCalls, 0, "an untouched party leaves that mod alone")
  end

  -- DISABLED, not absent: mod.find calls isActive (src/mods/Loader.lua:1239)
  -- and answers nil for a mod that is switched off or failed to load, so the
  -- guard is the same one. A player who turned Wilds of Kanto off must not
  -- have this screen reaching into it anyway.
  do
    loaderRef.mods[OW] = { enabled = false, failed = false,
                            manifest = { version = "2.1.8" } }
    local game = fakeGame({ mon(anySpecies, 5) }, { mon(anySpecies, 9) })
    game.overworld = { fake = "the overworld" }
    local screen = factory.new(game)
    syncCalls = 0
    table.insert(game.save.party, game.save.boxes[1][1])
    local ok = pcall(function() screen:exit() end)
    T.check(ok, "a disabled Wilds of Kanto does not break the exit")
    T.eq(syncCalls, 0, "and is not reached into")
    loaderRef.mods[OW] = { enabled = true, failed = false,
                            manifest = { version = "2.1.8" } }
  end

  -- An OLDER Wilds of Kanto, from before syncAll existed: the export is
  -- simply not there, and a missing export must degrade to the engine
  -- follower rather than throwing on the way out of a screen.
  do
    loaderRef.exports[OW] = { spriteProviders = {} }
    local game = fakeGame({ mon(anySpecies, 5) }, { mon(anySpecies, 9) })
    game.overworld = { fake = "the overworld" }
    local screen = factory.new(game)
    table.insert(game.save.party, game.save.boxes[1][1])
    local ok = pcall(function() screen:exit() end)
    T.check(ok, "a Wilds of Kanto without syncAll does not break the exit")
  end

  -- On GOLD the world is spelled differently, and that is what has to reach
  -- the other mod: it takes the live overworld as its second argument.
  do
    loaderRef.exports[OW] = {
      syncAll = function(g, ow) syncCalls = syncCalls + 1; sawGame, sawOw = g, ow end,
    }
    local game = fakeGame({ mon(anySpecies, 5) }, { mon(anySpecies, 9) })
    game.overworld = nil
    game.world = { fake = "Gold's world" }
    game.save.generation = 2
    local screen = factory.new(game)
    syncCalls = 0
    table.insert(game.save.party, game.save.boxes[1][1])
    screen:exit()
    T.eq(syncCalls, 1, "on Gold it is still called")
    T.check(sawOw == game.world, "and handed Gold's own world")
  end

  loaderRef.mods[OW] = nil
  loaderRef.exports[OW] = nil

  -- and with that mod absent it is one nil check, not a throw
  do
    local game = fakeGame({ mon(anySpecies, 5) }, { mon(anySpecies, 9) })
    game.overworld = { fake = "the overworld" }
    local screen = factory.new(game)
    table.insert(game.save.party, game.save.boxes[1][1])
    local ok = pcall(function() screen:exit() end)
    T.check(ok, "with Wilds of Kanto absent, closing the screen still works")
  end
end

-- ------- ...and it comes back where it was standing
--
-- 1.9.2 rebuilt the right follower and put it in the wrong place: it
-- reappeared ON the player rather than behind him, which is the second half
-- of issue #3. Not a choice this screen makes -- syncAll always asks for
-- `mapEnter = true` (lib/follower/control_engine.lua:4056-4060), and a map
-- entry with no walked trail behind it parks the pack on the player's own
-- cell so it walks out from under him. Nobody walks anywhere while the box
-- is open, so that is the branch that runs every time.
--
-- The stub below is that behaviour in miniature: it throws the trailers away
-- and rebuilds them parked on the player, the way the real re-seed does.
do
  local loaderRef = run.loader
  loaderRef.mods = loaderRef.mods or {}
  loaderRef.exports = loaderRef.exports or {}
  local OW = "overworld_wild_spawns"
  local anySpecies = next(Data.pokemon)

  local function fakeOw()
    return {
      player = { cellX = 7, cellY = 4 },
      -- the follower where it really is: one cell below, behind a player
      -- walking up, with that mod's own sub-pixel draw-order bias on py
      pokepcTrailers = { {
        cellX = 7, cellY = 5, facing = "up",
        px = 7 * 16, py = 5 * 16 + 0.5, _wildsDrawBias = 0.5,
      } },
      pokepcTrailCells = { { x = 7, y = 5 } },
    }
  end

  -- syncAll as the real one behaves: the old trailer is gone, a NEW one
  -- stands on the player, and the trail cell it will walk down points there
  local function parkOnPlayer(_g, ow)
    ow.pokepcTrailers = { {
      cellX = ow.player.cellX, cellY = ow.player.cellY, facing = "down",
      px = ow.player.cellX * 16, py = ow.player.cellY * 16 + 0.5,
      _wildsDrawBias = 0.5,
    } }
    ow.pokepcTrailCells = { { x = ow.player.cellX, y = ow.player.cellY } }
  end

  loaderRef.mods[OW] = { enabled = true, failed = false,
                          manifest = { version = "2.1.9" } }
  loaderRef.exports[OW] = { syncAll = parkOnPlayer }

  do
    local game = fakeGame({ mon(anySpecies, 5) }, { mon(anySpecies, 9) })
    game.overworld = fakeOw()
    local screen = factory.new(game)
    table.insert(game.save.party, game.save.boxes[1][1])
    table.remove(game.save.boxes[1], 1)
    screen:exit()

    local trailer = game.overworld.pokepcTrailers[1]
    T.eq(trailer.cellX, 7, "the rebuilt follower is put back on its own column")
    T.eq(trailer.cellY, 5, "and its own row -- behind the player, not under him")
    T.eq(trailer.px, 7 * 16, "px follows the cell")
    T.eq(trailer.py, 5 * 16 + 0.5,
      "and py with that mod's own draw-order bias kept")
    T.eq(trailer.facing, "up", "facing as it was standing")
    T.check(trailer.targetX == nil and trailer.moving == false,
      "and standing still, rather than sliding to where it was put")
    T.eq(game.overworld.pokepcTrailCells[1].y, 5,
      "the trail cell moves with it, or the next step pulls it back onto the player")
  end

  -- A trailer that came back somewhere else was placed deliberately -- that
  -- mod's own grow/trim path keeps positions -- and is left exactly alone.
  do
    loaderRef.exports[OW] = {
      syncAll = function(_g, ow)
        ow.pokepcTrailers = { { cellX = 9, cellY = 9, facing = "left",
                                px = 9 * 16, py = 9 * 16 } }
        ow.pokepcTrailCells = { { x = 9, y = 9 } }
      end,
    }
    local game = fakeGame({ mon(anySpecies, 5) }, { mon(anySpecies, 9) })
    game.overworld = fakeOw()
    local screen = factory.new(game)
    table.insert(game.save.party, game.save.boxes[1][1])
    screen:exit()
    local trailer = game.overworld.pokepcTrailers[1]
    T.eq(trailer.cellX, 9, "a follower placed somewhere of its own is not moved")
    T.eq(trailer.cellY, 9, "on either axis")
  end

  -- An overworld with no trailers at all, and one with no player: the
  -- restore is bookkeeping over another mod's tables and must not be the
  -- thing that throws on the way out of a screen.
  do
    loaderRef.exports[OW] = { syncAll = function() end }
    local game = fakeGame({ mon(anySpecies, 5) }, { mon(anySpecies, 9) })
    game.overworld = { fake = "an overworld with nothing on it" }
    local screen = factory.new(game)
    table.insert(game.save.party, game.save.boxes[1][1])
    T.check(pcall(function() screen:exit() end),
      "an overworld with no trailers closes the screen cleanly")

    local bare = fakeGame({ mon(anySpecies, 5) }, { mon(anySpecies, 9) })
    bare.overworld = { pokepcTrailers = { { cellX = 1, cellY = 1 } } }
    local bareScreen = factory.new(bare)
    table.insert(bare.save.party, bare.save.boxes[1][1])
    T.check(pcall(function() bareScreen:exit() end),
      "and so does one with trailers but no player")
  end

  loaderRef.mods[OW] = nil
  loaderRef.exports[OW] = nil
end

T.finish("gen3_box")
