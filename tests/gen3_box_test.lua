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

-- ------- WHAT'S NEW, marked as already read
--
-- The popup opens on the first screen built after an update and owns every
-- key while it is open, which is the point of it -- and which would make
-- every keypress in this file land on a page of release notes. So the save
-- says the notes have been read, exactly as a second boot would, and the
-- block at the bottom of this file unsets it to test the popup itself.
run.loader.modSave = run.loader.modSave or {}
run.loader.modSave.gen3_box = run.loader.modSave.gen3_box or {}
local newsStore = run.loader.modSave.gen3_box
-- The stamp does NOT copy the mod's constant. Copying it glues this file to
-- one version: the first NEWS_VERSION bump parts the two, the popup opens in
-- every screen built here and eats every keypress, and tests blow up in
-- places that have nothing to do with release notes. That is exactly what
-- happened to the dex suite on the way to 0.18.0.
--
-- A FUTURE stamp survives any bump instead: the check is OLDER-THAN, so a
-- save newer than the build never reopens the panel. The block at the bottom
-- unsets it to test the popup for real, and there is a test devoted to the
-- rule about when it is allowed to open.
local NEWS_SEEN_FUTURE = "99999.0.0"
newsStore.newsSeen = NEWS_SEEN_FUTURE

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

  -- ------- una riga che non puo' fare niente non si mostra
  --
  -- GRID e' l'unica: layout() legge CLASSIC su Gold qualunque cosa dica
  -- l'opzione, perche' Game2:draw non ha il gancio uiSize a cui BIG
  -- dovrebbe chiedere. Prima la riga c'era lo stesso, con "(GEN 1 ONLY)"
  -- attaccato all'etichetta -- cioe' una riga di menu che esiste solo per
  -- spiegare perche' non fa niente.
  --
  -- Lo schema si pubblica due volte: al load, quando l'unica cosa da
  -- chiedere e' la versione della ROM, e di nuovo su game.ready, quando un
  -- game c'e' davvero. E' il secondo passaggio che si guida da qui.
  local function rowsOf(loader)
    local out = {}
    for _, row in ipairs((loader.optionSchemas or {}).gen3_box or {}) do
      out[row.key] = true
    end
    return out
  end

  T.check(rowsOf(run.loader).grid,
    "su un boot Gen 1 la riga GRID c'e' come sempre")

  -- ------- FAVOURITE sta in fondo, e ci resta
  --
  -- Su e giu' camminano la lista dei posti. Una categoria che e' un
  -- puntatore a un'altra non ha niente da fare in mezzo ai posti veri, dove
  -- si legge come una scena che non e' riuscita a disegnarsi: sta alla fine
  -- del giro, per quante scene si aggiungano davanti.
  do
    local list = run.loader.exports.gen3_box.wallpapers
    T.eq(list[#list].id, "FAVE", "FAVOURITE e' l'ultima categoria della lista")
    local seen = {}
    for i, w in ipairs(list) do seen[w.id] = i end
    T.check(seen.FAVE > (seen["90S"] or 0) and seen.FAVE > (seen.SAKURA or 0),
      "e viene dopo ogni posto vero, comprese le scene aggiunte dopo")
  end

  local goldGame = { save = { generation = 2 } }
  Runtime.emit("game.ready", { game = goldGame })
  local afterGold = rowsOf(gen2Run.loader)
  T.check(not afterGold.grid,
    "con un game Gold in mano la riga GRID sparisce: non puo' fare niente")
  T.check(afterGold.bands,
    "mentre le righe che valgono su entrambi restano")

  -- e non e' una rimozione a senso unico: un boot Gen 1 la ripubblica
  Runtime.emit("game.ready", { game = { save = { generation = 1 } } })
  T.check(rowsOf(gen2Run.loader).grid,
    "e su un game Gen 1 torna, perche' li' fa qualcosa")

  local gen2Factory = D.screens and D.screens.Gen3Box
  T.check(gen2Factory ~= nil, "and registers the screen on that boot")

  -- questo e' un SECONDO loader, con un salvataggio suo: anche qui le note
  -- di rilascio risultano gia' lette, o il popup si prende i tasti
  gen2Run.loader.modSave = gen2Run.loader.modSave or {}
  gen2Run.loader.modSave.gen3_box = gen2Run.loader.modSave.gen3_box or {}
  gen2Run.loader.modSave.gen3_box.newsSeen = NEWS_SEEN_FUTURE

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
    "FIND|SORT|JUMP TO BOX|NAME BOX|WALLPAPER|MARK MODE|MOVE MANY|WHAT'S NEW|CANCEL",
    "holding FIND, SORT, JUMP TO BOX, NAME BOX, WALLPAPER, MARK MODE, MOVE MANY, WHAT'S NEW and CANCEL")

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

  -- ------- the window is a COLUMN, so DOWN has to move in it
  --
  -- PLAN.md specified a row of four symbols and gave this window LEFT and
  -- RIGHT. drawMarkWindow draws the four names stacked, one per line, so
  -- the press a player actually makes -- DOWN, on a vertical list -- moved
  -- nothing, and the panel read as dead. Whichever way the drawing goes
  -- next, the keys that match it have to keep working.
  do
    local MARKS = 4 -- CIRCLE, SQUARE, TRIANGLE, HEART
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
    T.check(screen.markWindow ~= nil, "the window opened")
    T.eq(screen.markWindow.cursor, 1, "it starts on the first symbol")

    game.press("down"); screen:update()
    T.eq(screen.markWindow.cursor, 2, "DOWN moves to the second symbol")
    game.press("up"); screen:update()
    T.eq(screen.markWindow.cursor, 1, "UP moves back to the first")
    game.press("up"); screen:update()
    T.eq(screen.markWindow.cursor, MARKS,
      "and UP off the top wraps to the last, as LEFT always did")
    game.press("down"); screen:update()
    T.eq(screen.markWindow.cursor, 1, "DOWN off the bottom wraps to the first")

    -- the pair the plan shipped is not taken away from anyone who learned it
    game.press("right"); screen:update()
    T.eq(screen.markWindow.cursor, 2, "RIGHT still moves too")
  end

  -- ------- and the chosen row wears the game's ARROW, not a rectangle
  --
  -- "nel menu non c'e' cursore". A thin black box ruled around black text
  -- on a white panel is not a cursor, it is a border: the window looked
  -- like nothing was selected. Every other menu in the game marks its row
  -- with Theme.cursor through Font.drawCode, and so does this one now.
  do
    local Theme = require("src.ui.Theme")
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
    T.check(screen.markWindow ~= nil, "the window opened")

    local realDrawCode = Font.drawCode
    local codes = {}
    Font.drawCode = function(c, x, y) codes[#codes + 1] = { code = c, x = x, y = y } end
    screen:draw()
    Font.drawCode = realDrawCode

    local arrows = {}
    for _, c in ipairs(codes) do
      if c.code == Theme.cursor then arrows[#arrows + 1] = c end
    end
    T.eq(#arrows, 1, "exactly one arrow is drawn in the marking window")

    -- and it follows the selection down the column rather than sitting still
    local firstY = arrows[1].y
    game.press("down"); screen:update()
    codes = {}
    Font.drawCode = function(c, x, y) codes[#codes + 1] = { code = c, x = x, y = y } end
    screen:draw()
    Font.drawCode = realDrawCode
    local moved = nil
    for _, c in ipairs(codes) do
      if c.code == Theme.cursor then moved = c end
    end
    T.check(moved and moved.y > firstY,
      "and it moves down the column with the selection")
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

  -- ------- e SOPRA UNA SCENA le zone per cella non ci sono proprio
  --
  -- Una zona e' un RETTANGOLO e il rimappaggio dentro legge il canale
  -- rosso: un cielo chiaro sta sopra 0.83 e finisce sull'ombra 0, che in
  -- una tavolozza di specie e' BIANCA. Cosi' la cella con dentro un
  -- Pokemon si ridipingeva -- bianca dove la scena era chiara -- e quella
  -- accanto no: una scacchiera sopra il disegno. Il Pokedex ha spedito lo
  -- stesso errore e li' e' stato segnalato per primo, come il cartoncino
  -- bianco sotto i catturati.
  --
  -- Il rimappaggio si sposta quindi sulla FIGURA (drawPic manda i colori
  -- della specie a PaletteFX.shader), e qui si guarda che il rettangolo
  -- non venga piu' emesso.
  do
    local full = fakeGame({ mon("FIXMON_A", 5), mon("FIXMON_B", 3) })
    local s2 = factory.new(full)
    local papers = store.boxPapers or {}
    store.boxPapers = papers
    papers[1] = { id = "PLAIN", art = 1 }
    -- il dataset di prova non porta tavolozze di specie, e senza quelle non
    -- si emette nessuna zona per cella: qui se ne presta una, perche' quello
    -- che si sta verificando e' la REGOLA (con scena no, senza scena si) e
    -- non da dove escono i quattro colori
    local realMonPal = PaletteFX.monPal
    if not PaletteFX.monPal(Data, "FIXMON_A") then
      PaletteFX.monPal = function()
        return { { 255, 255, 255 }, { 200, 110, 90 }, { 120, 60, 40 }, { 0, 0, 0 } }
      end
    end
    local plain = s2:sgbPalettes(full)
    local perCell = plain and (#plain - 1) or 0
    if perCell > 0 then
      papers[1] = { id = "SEA", art = 1 }
      local onScene = s2:sgbPalettes(full)
      T.eq(#onScene, 1,
        "sopra una scena c'e' solo la zona di fondo, niente rettangoli per cella")
      T.check(onScene[1].colors == false,
        "e quella di fondo esce dal rimappaggio")
      T.check(s2.remapOff(),
        "e lo schermo lo sa: i colori viaggiano con la figura")
      papers[1] = { id = "PLAIN", art = 1 }
      T.check(not s2.remapOff(),
        "senza scena invece il rimappaggio c'e' e le zone tornano")
      T.eq(#s2:sgbPalettes(full), 1 + perCell,
        "una per Pokemon nella pagina, come sempre")
    else
      T.check(true, "dataset senza tavolozze di specie: zone non verificabili")
    end
    PaletteFX.monPal = realMonPal
    papers[1] = { id = "SEA", art = 1 }
  end

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

  -- ------- una scena dipinta si muove, e la sua cucitura non entra mai
  --
  -- Un livello dipinto non puo' ciclare: scorrerlo trascinerebbe il taglio
  -- attraverso la box ogni pochi secondi. Ma e' piu' largo dello schermo, e
  -- dentro quel margine puo' andare e tornare senza mai avvolgersi. Le due
  -- meta' della promessa, e servono entrambe: si muove nel tempo, E lo
  -- scostamento resta nel margine, cosi' una sola copia della striscia
  -- copre lo schermo e la seconda -- quella che mostrerebbe la giunta --
  -- non viene mai disegnata.
  do
    local G = love.graphics
    local realDraw = G.draw
    local Assets2 = require("src.render.Assets")
    local realImage = Assets2.image
    Assets2.image = function()
      return { getWidth = function() return 320 end,
               getHeight = function() return 144 end }
    end
    local at = {}
    G.draw = function(_, x) at[#at + 1] = x end

    local painted = { layers = { { image = "painted.png", speed = 0 } } }
    local screen2 = factory.new(fakeGame({}))
    local places, copies, escaped = {}, 0, false
    for tick = 0, 6000, 250 do
      at = {}
      screen2.drawArt(painted, 160, 144, tick)
      if at[1] then
        places[tostring(at[1])] = true
        copies = math.max(copies, #at)
        if at[1] > 0 or at[1] < -160 then escaped = true end
      end
    end
    G.draw, Assets2.image = realDraw, realImage

    local n = 0
    for _ in pairs(places) do n = n + 1 end
    T.check(n > 1, "una scena dipinta non e' un'immagine morta: si sposta")
    T.check(not escaped, "e non esce mai dal proprio margine")
    T.eq(copies, 1, "quindi una copia sola copre lo schermo, "
      .. "e la giunta non entra mai nel riquadro")
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
  -- PEEK draws a column of the neighbouring box at each margin, which is
  -- four more washes a side: real, wanted, and not what these checks are
  -- counting. They are about the grid.
  opts.peek = false

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

    -- e la banda del titolo e' alta quanto la SCRITTA, non quanto il margine
    -- sopra la griglia. In CLASSIC sono gli stessi 14 pixel; in BIG il
    -- margine e' 32, e il titolo stava su una lastra bianca con ventidue
    -- pixel vuoti sotto -- un bordo bianco in cima alla scena
    local topBands = {}
    local realRect3 = G.rectangle
    G.rectangle = function(mode, x, y, w, h)
      if mode == "fill" and x == 0 and y == 0 and w == 320 then
        topBands[#topBands + 1] = h
      end
    end
    opts.grid = "big"
    factory.new(game):draw()
    opts.grid = "classic"
    G.rectangle = realRect3
    local slab = false
    for _, h in ipairs(topBands) do if h > 14 then slab = true end end
    T.check(not slab,
      "e in BIG la banda del titolo e' alta quanto la scritta, non quanto "
      .. "il margine sopra la griglia")
  end

  -- ------- la scena si dipinge su una superficie sua
  --
  -- Ogni scena disegna di proposito oltre i propri bordi: le onde partono da
  -- -8, le forme anni '90 da -30, e una striscia si affianca finche' non
  -- copre la larghezza. Su Gen 1 non costa niente -- Game:draw da' alla UI
  -- una canvas grande esattamente come lo schermo, che taglia -- ma Gold
  -- compone dentro una canvas grande quanto la finestra e quella roba
  -- finiva sul bordo bianco intorno allo schermo Game Boy.
  --
  -- Due tentativi con lo scissor sono stati sbagliati, il secondo al punto
  -- da far sparire tutti i wallpaper su Gold: uno scissor e' un rettangolo
  -- in uno spazio diverso da quello in cui si disegna, e indovinare QUALE
  -- da qui non si puo'. Quindi non si indovina: la scena si dipinge su una
  -- superficie grande come lo schermo e si posa all'origine. Una canvas non
  -- ha coordinate fuori da se stessa, quindi quello che cade oltre il bordo
  -- e' perso per costruzione, su qualsiasi boot e sotto qualsiasi
  -- trasformata.
  do
    local G = love.graphics
    local realNew, realSetC = G.newCanvas, G.setCanvas
    local realRect, realDraw = G.rectangle, G.draw
    local asked, target, onSurface, blits = {}, nil, 0, {}
    G.newCanvas = function(w, h)
      local c = realNew(w, h)
      asked[#asked + 1] = { w, h, c }
      return c
    end
    G.setCanvas = function(c) target = c; return realSetC(c) end
    G.rectangle = function() if target then onSurface = onSurface + 1 end end
    G.draw = function(img, x, y) blits[#blits + 1] = { img, x, y } end

    opts.grid = "classic"
    factory.new(game):draw()

    G.newCanvas, G.setCanvas = realNew, realSetC
    G.rectangle, G.draw = realRect, realDraw

    -- Le superfici si tengono in cache PER MISURA, quindi una 160x144 puo'
    -- gia' esistere da un disegno precedente e `asked` restare vuota: quello
    -- che conta non e' che la canvas sia stata creata adesso, ma che la
    -- scena finisca su una canvas grande quanto lo schermo e che quella
    -- venga posata all'origine. Si guarda quindi il BLIT, che e' vero in
    -- entrambi i casi.
    local surface
    for _, a in ipairs(asked) do
      if a[1] == 160 and a[2] == 144 then surface = a[3] end
    end
    T.check(onSurface > 0, "la scena si dipinge su una superficie propria")
    T.eq(target, nil, "poi rimette il bersaglio dove l'aveva trovato")
    local posed = false
    for _, b in ipairs(blits) do
      local img = b[1]
      local okDim, iw, ih = pcall(function()
        return img:getWidth(), img:getHeight()
      end)
      if b[2] == 0 and b[3] == 0
         and ((surface and img == surface) or (okDim and iw == 160 and ih == 144)) then
        posed = true
      end
    end
    T.check(posed,
      "e una superficie grande come lo schermo si posa all'origine, dove sta la box")

    -- e senza canvas non resta un buco: si dipinge dritti sullo schermo,
    -- che sbordera' -- ma una macchia sul bordo e' meglio di una box vuota
    local hadNew = G.newCanvas
    G.newCanvas = nil
    local painted = 0
    G.rectangle = function() painted = painted + 1 end
    local okBare = pcall(function() factory.new(game):draw() end)
    G.rectangle, G.newCanvas = realRect, hadNew
    T.check(okBare and painted > 0,
      "e senza canvas la scena si dipinge lo stesso, dritta sullo schermo")
  end

  -- ------- le box accanto, tagliate dal bordo
  --
  -- Pokemon Box sul GameCube mostra le vicine mozzate ai due lati, ed e'
  -- quello che fa leggere il deposito come uno scaffale davanti a cui stai
  -- invece che come una pagina da voltare. Qui e' una striscia larga quanto
  -- il margine: niente ritagli a mano, taglia il bordo dello schermo.
  do
    local L = screen.layout()
    opts.peek = false
    local without = 0
    G.rectangle = function(mode, x, y, w, h)
      if mode == "fill" and w == h and w == L.cell then without = without + 1 end
    end
    screen:draw()

    opts.peek = true
    local with = 0
    G.rectangle = function(mode, x, y, w, h)
      if mode == "fill" and w == h and w == L.cell then with = with + 1 end
    end
    screen:draw()
    G.rectangle = realRect

    T.check(with > without,
      "con PEEK acceso si disegnano anche le celle delle box accanto")
    T.eq(with - without, 8,
      "una colonna per lato, quattro celle ciascuna")
    opts.peek = false
  end

  -- ------- BANDS: quanto schermo prende la scena
  --
  -- La riga del titolo e il piede sono ridipinti di bianco perche' sono
  -- testo nero, ed e' quello che fa anche Gen 3. Sotto SOLID pero' la scena
  -- ci passa sotto e prende tutto lo schermo, e allora le scritte devono
  -- portarsi dietro il proprio bordo: senza alone, una didascalia nera su
  -- un cielo notturno non la legge nessuno. Le due meta' si verificano
  -- insieme, perche' una senza l'altra e' un peggioramento.
  do
    local Font = require("src.render.Font")
    local realRect, realColor, realFont = G.rectangle, G.setColor, Font.draw
    local tone = { 0, 0, 0, 1 }
    local bands, glyphs, plates, inks = {}, 0, 0, {}
    G.setColor = function(r, g, b, a) tone = { r, g, b, a or 1 } end
    G.rectangle = function(mode, x, y, w, h)
      -- le due bande e nient'altro: piena larghezza, alte 14
      if mode == "fill" and x == 0 and w == 160 and h == 14 then
        bands[#bands + 1] = { tone[1], tone[2], tone[3], tone[4] }
      -- un piano sotto una didascalia: alto come la riga, largo come la
      -- scritta, e opaco qualunque cosa faccia la banda
      elseif mode == "fill" and h == 12 and w < 160 and tone[4] == 1 then
        plates = plates + 1
      end
    end
    Font.draw = function()
      glyphs = glyphs + 1
      -- di che colore e' l'inchiostro nel momento in cui si scrive
      inks[#inks + 1] = { tone[1], tone[2], tone[3] }
      return 0
    end

    local function drawn(setting)
      opts.bands = setting
      bands, glyphs, plates, inks = {}, 0, 0, {}
      factory.new(game):draw()
      return bands, glyphs
    end

    local solid, solidGlyphs = drawn("SOLID")
    local platesSolid, inksSolid = plates, inks
    T.eq(#solid, 2, "SOLID dipinge le due bande")
    T.check(solid[1] and solid[1][4] == 1 and solid[2][4] == 1,
      "e le dipinge piene")

    -- e non le dipinge BIANCHE: il bianco e' un adesivo appiccicato sopra
    -- un quadro. Ogni scena porta quattro toni e il piu' chiaro e' un
    -- quasi-bianco della sua stessa tinta, quindi la banda fa parte della
    -- scena e regge lo stesso il testo nero
    local seaLightest
    for _, w in ipairs(run.loader.exports.gen3_box.wallpapers) do
      if w.id == "SEA" then seaLightest = w.palette[1] end
    end
    T.check(seaLightest ~= nil, "SEA ha una palette da cui prendere il tono")
    local c = solid[1]
    T.check(math.abs(c[1] - seaLightest[1] / 255) < 0.005
        and math.abs(c[2] - seaLightest[2] / 255) < 0.005
        and math.abs(c[3] - seaLightest[3] / 255) < 0.005,
      "e le tinge col tono piu' chiaro della scena, non di bianco")

    local half = drawn("60")
    T.eq(#half, 2, "al 60% le bande ci sono ancora")
    T.check(math.abs((half[1][4] or 0) - 0.6) < 0.001,
      "ma la scena si vede attraverso")

    local thin, haloGlyphs = drawn("15")
    T.check(math.abs((thin[1][4] or 0) - 0.15) < 0.001,
      "in fondo alla scala resta un velo, non il nulla: una didascalia non "
      .. "deve combattere con la scena che ha esattamente il suo colore")
    -- e le didascalie si scrivono con UN inchiostro solo: nero su una scena
    -- chiara, bianco su una scura. Prima erano un piano bianco (un adesivo)
    -- e poi due toni della palette con un bordino (grasse e sdoppiate su un
    -- cielo pallido). Sopra un quadro il tipo vuole la cosa piu' semplice
    -- che resti leggibile.
    local flat = 0
    for _, c in ipairs(inks) do
      if (c[1] == 1 and c[2] == 1 and c[3] == 1) or (c[1] == 0 and c[2] == 0 and c[3] == 0) then
        flat = flat + 1
      end
    end
    T.eq(flat, #inks,
      "e ogni didascalia si scrive in un inchiostro piatto, mai in un tono "
      .. "della scena")
    T.check(#inks > 0, "SEA e' una scena chiara, quindi le scritte sono nere")
    local blackSolid = 0
    for _, c in ipairs(inksSolid) do
      if c[1] == 0 and c[2] == 0 and c[3] == 0 then blackSolid = blackSolid + 1 end
    end
    T.eq(blackSolid, #inksSolid,
      "mentre con SOLID restano nere sulla banda, come sempre")

    -- zero resta onorato per un save che se lo porta dietro, anche se il
    -- menu non lo offre piu'
    local none = drawn("0")
    T.eq(#none, 0, "e uno zero scritto a mano toglie le bande del tutto")

    opts.bands = nil
    G.rectangle, G.setColor, Font.draw = realRect, realColor, realFont
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

-- ------- FULL SCREEN
--
-- The surface follows the device instead of the Game Boy, and the room goes
-- on MORE BOXES rather than bigger ones: as many 5x4 panels as fit, across
-- first and then down, each with its own name and its own wallpaper. What
-- is asserted here is the arithmetic and the walking, because the look is
-- what the offline renderer is for.
do
  local optStore = run.loader.modOptions.gen3_box
  optStore.fullscreen = true

  local G = love.graphics
  local realDim = G.getDimensions
  -- LuaJIT is 5.1: table.unpack does not exist, unpack does
  local unpack = table.unpack or unpack
  local function withWindow(w, h, fn)
    G.getDimensions = function() return w, h end
    local out = { fn() }
    G.getDimensions = realDim
    return unpack(out)
  end

  -- the surface stays inside what the engine will take: below 160x144 or
  -- above 640x576 setUISize silently falls back to a Game Boy screen
  for _, size in ipairs({ { 1080, 2160 }, { 1080, 1920 }, { 2400, 1080 },
                          { 1600, 1200 }, { 320, 240 } }) do
    local w, h = withWindow(size[1], size[2], function()
      local s = factory.new(fakeGame({}))
      return s:uiSize()
    end)
    T.check(w >= 160 and w <= 640 and h >= 144 and h <= 576,
      string.format("una finestra %dx%d chiede una superficie che l'engine accetta (%dx%d)",
        size[1], size[2], w, h))
    T.check(w % 8 == 0 and h % 8 == 0,
      "e in tessere intere, o una zona di palette parte a meta' tessera")
  end

  -- on a phone that means several boxes at once, not one enormous one
  optStore.grid = "big"
  withWindow(1080, 2160, function()
    local s = factory.new(fakeGame({}))
    local L = s.layout()
    T.check(L.full, "col pieno schermo acceso la disposizione e' quella piena")
    -- Piu' di una, non "il piu' possibile": la cella e' quella grande, cioe'
    -- quella dove la figura del Pokemon si disegna intera invece che
    -- dimezzata. Prima si spende la stanza per far vedere i Pokemon, poi
    -- per farne stare tante.
    T.eq(L.cell, 56, "in pieno schermo con GRID BIG la cella e' quella grande")
    T.check((L.acrossN or 1) * (L.downN or 1) >= 2,
      "e su un telefono ci sta piu' di una box")
    T.check(L.acrossN >= 1 and L.downN >= L.acrossN,
      "in verticale: prima in orizzontale finche' ci stanno, poi in giu'")
  end)

  -- GRID non viene piu' scavalcato: sceglie la CELLA, e quella domanda ha
  -- due risposte anche su una superficie grande quanto lo schermo. Chi
  -- sceglie CLASSIC e si vede celle da 56 legge l'opzione come rotta --
  -- ed e' esattamente come e' stata segnalata.
  optStore.grid = "classic"
  withWindow(1080, 2160, function()
    local s = factory.new(fakeGame({}))
    local L = s.layout()
    T.eq(L.cell, 28, "in pieno schermo GRID CLASSIC da' la cella piccola")
    T.eq(L.panelW, 5 * 28 + 8, "e il pannello si stringe con lei")
    T.eq(L.panelH, 4 * 28 + 24, "in altezza come in larghezza")
    local big = withWindow(1080, 2160, function()
      optStore.grid = "big"
      local L2 = factory.new(fakeGame({})).layout()
      optStore.grid = "classic"
      return (L2.acrossN or 1) * (L2.downN or 1)
    end)
    T.check((L.acrossN or 1) * (L.downN or 1) > big,
      "e con la cella piccola ci stanno piu' box che con quella grande")
  end)
  optStore.grid = "big"

  -- walking off a panel goes to the NEXT PANEL, and only past the last one
  -- does the page of boxes move. How many panels there are depends on the
  -- window, so the assertions ask the layout rather than assuming a shape.
  local function panelBoxOf(s)
    local n = 12
    return ((s.pageBox or 1) - 1 + (s.panel or 0)) % n + 1
  end
  withWindow(1080, 2160, function()
    local g = fakeGame({})
    local s = factory.new(g)
    local L = s.layout()
    s.panel, s.col, s.row = 0, 4, 0
    local page = s.pageBox or 1
    g.press("right"); s:update()
    if L.acrossN > 1 then
      -- su una tela larga il pannello accanto c'e', e ci si passa
      T.eq(s.panel, 1, "dal bordo destro si passa al pannello accanto")
      T.eq(s.pageBox or 1, page, "senza muovere la pagina di box")
      T.eq(g.save.currentBox, 2, "e la box su cui si agisce e' quella del pannello")
    else
      -- su una tela stretta (un telefono in mano) di pannelli ce n'e' uno
      -- per riga, quindi il bordo destro scorre la pagina
      T.check((s.pageBox or 1) ~= page,
        "su una colonna sola il bordo destro scorre la pagina di box")
      T.eq(g.save.currentBox, panelBoxOf(s), "e la box segue il pannello")
    end

    -- giu' dall'ultima riga di pannelli scorre la pagina in ogni caso
    s.panel = (L.acrossN * L.downN) - 1
    s.row = 3
    local before = s.pageBox or 1
    g.press("down"); s:update()
    T.check((s.pageBox or 1) ~= before,
      "e sotto l'ultimo pannello la pagina scorre")
  end)

  -- ------- ogni pannello ha il suo nome, e il nome apre il suo menu
  --
  -- Su una schermata con otto box, il BOX MENU non puo' stare su una riga
  -- sola in cima: sarebbe il menu di una box e non delle altre sette. Il
  -- nome di ogni pannello E' il suo header -- su dalla prima riga ci si
  -- arriva, A lo apre, e la box su cui agisce e' quella del pannello.
  withWindow(1080, 2160, function()
    local g = fakeGame({})
    local s = factory.new(g)
    s.panel, s.col, s.row, s.header = 0, 0, 0, false

    g.press("up"); s:update()
    T.check(s.header, "su dalla prima riga si arriva al nome del pannello")
    T.eq(g.save.currentBox, panelBoxOf(s),
      "e il nome e' quello della box del pannello, non di un'altra")

    -- e da li' su si continua: non e' un vicolo cieco
    local wasPanel = s.panel
    g.press("up"); s:update()
    T.check(not s.header, "su ancora esce dal nome invece di restare fermi")
    T.check(s.panel ~= wasPanel or (s.pageBox or 1) ~= 1,
      "andando al pannello sopra, o scorrendo la pagina se non c'e'")
    T.eq(s.row, 3, "e ci si arriva dalla riga in fondo, non dalla prima")
  end)

  -- ------- FIND e JUMP TO BOX devono PORTARTI su quella box
  --
  -- Con una box per volta e' automatico: cambi il numero e stai guardando
  -- quella. In pieno schermo no -- la box puo' non essere nemmeno nella
  -- pagina, e prima cambiava il numero lasciando il cursore nel pannello
  -- dov'era, cioe' puntato su un'altra box. Un solo posto sa rendere
  -- visibile una box, e sia FIND che JUMP passano di li'.
  withWindow(1080, 2160, function()
    local g = fakeGame({})
    local s = factory.new(g)
    for _, target in ipairs({ 9, 2, 12, 5 }) do
      s.focusBox(target)
      T.eq(g.save.currentBox, target, "focusBox porta la box " .. target)
      T.eq(s.panelBox(s.panel or 0), target,
        "e il pannello sotto il cursore e' proprio quella, non un'altra")
      local L = s.layout()
      local shown = (L.acrossN or 1) * (L.downN or 1)
      T.check((s.panel or 0) < shown,
        "e il pannello e' fra quelli sullo schermo")
    end
  end)

  optStore.fullscreen = false
  optStore.grid = nil
end

-- ------- MOVE MANY
--
-- Pokemon Box on the GameCube takes a handful at once, and a storage screen
-- that moves them one at a time is one you use twice and then avoid. A
-- ticks, START moves everything ticked into the box being looked at.
--
-- The refusal matters as much as the move: a selection you cannot see the
-- end of must not half-arrive, so a destination without room for all of
-- them leaves both boxes exactly as they were.
do
  local g = fakeGame({})
  local s = factory.new(g)
  local boxes = g.save.boxes
  boxes[1] = { mon("FIXMON_A", 5), mon("FIXMON_B", 6), mon("FIXMON_A", 7) }
  boxes[2] = {}
  g.save.currentBox = 1

  -- il messaggio si mangia la pressione dopo, quindi si azzera a mano fra
  -- un tasto e l'altro -- la stessa trappola del blocco dei preferiti
  local function quiet() s.notice = nil end

  s.moveMany, s.manyBox, s.many = true, 1, {}
  s.col, s.row, s.header = 0, 0, false
  g.press("a"); s:update(); quiet()
  T.check(s.many[1], "A spunta lo slot sotto il cursore")
  g.press("a"); s:update(); quiet()
  T.check(not s.many[1], "e A di nuovo lo toglie: e' un interruttore")

  s.many = { [1] = true, [3] = true }
  g.save.currentBox = 2
  g.press("start"); s:update()
  T.eq(#boxes[1], 1, "START porta via dalla box delle spunte quelli spuntati")
  T.eq(#boxes[2], 2, "e li posa in quella che stai guardando")
  T.eq(boxes[1][1].level, 6, "lasciando indietro esattamente i non spuntati")
  quiet()

  -- niente mezze mosse: se non ci stanno tutti, non si muove nessuno
  boxes[3] = {}
  for i = 1, 19 do boxes[3][i] = mon("FIXMON_A", i) end
  boxes[4] = { mon("FIXMON_B", 1), mon("FIXMON_B", 2), mon("FIXMON_B", 3) }
  s.manyBox, s.many = 4, { [1] = true, [2] = true, [3] = true }
  g.save.currentBox = 3
  g.press("start"); s:update()
  T.eq(#boxes[4], 3, "una destinazione senza posto per tutti non ne prende nessuno")
  T.eq(#boxes[3], 19, "e la destinazione resta com'era")
  quiet()
end

-- ------- WHAT'S NEW
--
-- Il popup delle novita': si apre da solo la PRIMA volta dopo un
-- aggiornamento (o dopo l'installazione), si chiude e non torna piu'.
-- Tre cose vanno verificate qui e non a occhio: che si apra quando deve,
-- che si prenda i tasti mentre e' aperto (o il cursore gira dietro una
-- pagina che stai leggendo), e che ogni riga ENTRI nel riquadro -- una
-- riga che sborda e' esattamente il difetto che nessun test che guarda
-- solo "non e' crashato" vede mai.
do
  local Font = require("src.render.Font")
  local g = fakeGame({ mon("FIXMON_A", 5) })

  newsStore.newsSeen = nil
  local s = factory.new(g)
  T.check(s.news ~= nil, "senza note lette il popup si apre da solo")
  T.eq(s.news.page, 1, "dalla prima pagina")

  -- i tasti sono suoi: la freccia non muove il cursore nella griglia
  local row0, col0 = s.row, s.col
  g.press("down"); s:update()
  T.eq(s.row, row0, "mentre e' aperto il cursore non si muove")
  T.eq(s.col, col0, "in nessuna direzione")

  g.press("a"); s:update()
  T.eq(s.news.page, 2, "A gira pagina")
  g.press("left"); s:update()
  T.eq(s.news.page, 1, "e sinistra torna indietro")

  for _ = 1, #s.newsPages do
    if s.news then g.press("a"); s:update() end
  end
  T.check(s.news == nil, "A sull'ultima pagina chiude")
  T.eq(newsStore.newsSeen, s.newsVersion,
    "e il salvataggio si segna la versione letta")

  local s2 = factory.new(g)
  T.check(s2.news == nil, "riaprendo la schermata non torna")

  -- ...ma dal BOX MENU si rilegge quando si vuole
  s2.openNews()
  T.check(s2.news ~= nil, "la voce WHAT'S NEW lo riapre")
  g.press("b"); s2:update()
  T.check(s2.news == nil, "B chiude da qualsiasi pagina")

  -- ------- e adesso lo si DISEGNA davvero
  --
  -- La mod del Pokedex e' uscita con una chiamata a una funzione che non
  -- esisteva dentro drawNews, e l'applicazione si chiudeva al primo
  -- fotogramma del popup: nessun test aveva mai chiamato draw(), quindi la
  -- suite era verde su codice che non poteva girare. Qui ogni pagina viene
  -- disegnata davvero, in tutte e tre le disposizioni.
  do
    local optStore = run.loader.modOptions.gen3_box
    local wasGrid, wasFull = optStore.grid, optStore.fullscreen
    for _, mode in ipairs({ "classic", "big", "full" }) do
      optStore.grid = mode == "full" and "big" or mode
      optStore.fullscreen = (mode == "full")
      local s3 = factory.new(g)
      for page = 1, #s3.newsPages do
        s3.news = { page = page }
        local ok, err = pcall(function() s3:draw() end)
        T.check(ok, ("la pagina %d si disegna in %s (%s)")
          :format(page, mode, tostring(err)))
      end
      s3.news = nil
      local ok, err = pcall(function() s3:draw() end)
      T.check(ok, ("e la schermata si disegna in %s senza popup (%s)")
        :format(mode, tostring(err)))
    end
    optStore.grid, optStore.fullscreen = wasGrid, wasFull
  end

  -- ogni riga, avvolta contro la larghezza vera del riquadro, ci sta
  local L = s2.layout()
  local x, y, w, h, k = s2.newsRect(L)
  T.check(x >= 0 and y >= 0 and x + w <= L.w and y + h <= L.h,
    "il riquadro sta dentro la superficie")
  -- il testo si disegna a scala intera, quindi larghezze e altezze si
  -- misurano in pixel di FONT, non di schermo
  local inner = s2.newsInner(L)
  h = math.floor(h / k)
  local tooWide, tooTall = {}, {}
  for i, page in ipairs(s2.newsPages) do
    T.check(Font.width(page.title) <= inner,
      "il titolo della pagina " .. i .. " ci sta")
    local rows = 0
    for _, entry in ipairs(page.lines) do
      local text = type(entry) == "table" and entry[1] or entry
      for _, line in ipairs(s2.wrapNews(text, inner)) do
        rows = rows + 1
        if Font.width(line) > inner then
          tooWide[#tooWide + 1] = ("pagina %d: %s"):format(i, line)
        end
      end
    end
    -- 14 per il titolo, 12 per il piede, 10 per riga
    if 14 + rows * 10 + 12 > h then
      tooTall[#tooTall + 1] = ("pagina %d: %d righe"):format(i, rows)
    end
  end
  T.eq(#tooWide, 0, "nessuna riga sborda dal riquadro (" ..
    table.concat(tooWide, "; ") .. ")")
  T.eq(#tooTall, 0, "e nessuna pagina e' piu' lunga del riquadro (" ..
    table.concat(tooTall, "; ") .. ")")

  -- e il testo dice DOVE si trova la roba: una pagina che annuncia una
  -- feature senza dire come si raggiunge e' il problema, non la cura
  local all = {}
  for _, page in ipairs(s2.newsPages) do
    for _, entry in ipairs(page.lines) do
      all[#all + 1] = type(entry) == "table" and entry[1] or entry
    end
  end
  local blob = table.concat(all, " ")
  T.check(blob:find("BOX MENU"), "le note dicono dove si cambia lo sfondo")
  T.check(blob:find("OPTIONS"), "e dove si accende il pieno schermo")
  T.check(blob:find("CONTEST"), "e che il contest esiste")
end

-- ------- l'arte di un autore: quanto grande, e fin dove
--
-- Due volte questa riga ha sbagliato in due direzioni opposte:
-- `floor(h/ih)` lasciava cento righe bianche sotto una scena dentro un
-- pannello da 244, e `ceil(h/ih)` ha incontrato la tela alta 576 del
-- Pokedex e ha ingrandito una mattonella da 64 pixel NOVE volte. Nessun
-- test guardava la scala, perche' nel banco di prova le immagini sono
-- larghe zero e drawArt non disegna niente. Qui le immagini si prestano.
do
  local G = love.graphics
  local realNew, realDraw = G.newImage, G.draw
  local exports = run.loader.exports.gen3_box
  local paint = exports and exports.paintWallpaper
  T.check(type(paint) == "function", "la mod espone il pittore degli sfondi")
  if type(paint) == "function" then
    -- l'arte arriva da Assets.image, non da love.graphics.newImage: e' quel
    -- prestito che va intercettato, o drawArt vede un'immagine larga zero e
    -- si arrende in silenzio -- che e' il motivo per cui nessun test aveva
    -- mai guardato questa parte
    local Assets = require("src.render.Assets")
    local realImage = Assets.image
    local sizes = { ["strip.png"] = { 320, 144 }, ["tile.png"] = { 64, 64 } }
    local drawn
    Assets.image = function(path)
      local size = sizes[tostring(path)]
      if not size then return realImage(path) end
      return {
        _fake = true,
        getWidth = function() return size[1] end,
        getHeight = function() return size[2] end,
      }
    end
    G.draw = function(img, a, b, c, d, e, f)
      -- solo le immagini prestate qui: la superficie propria su cui la
      -- scena viene dipinta si posa con un draw suo, che non c'entra
      if not (type(img) == "table" and img._fake) then return end
      if type(a) == "table" then
        -- draw(img, quad, x, y, r, sx, sy): il ritaglio e' alto UN pixel
        -- (la riga in cima, stirata), quindi sy sono le righe coperte
        drawn[#drawn + 1] = { scale = e or 1, y = c or 0, rows = f or 1 }
      else
        -- draw(img, x, y, r, sx, sy): sy e' una scala, non un'altezza
        drawn[#drawn + 1] = { scale = d or 1, y = b or 0 }
      end
    end

    local paper = { id = "TEST", pattern = "PLAIN2",
                    palette = { { 255, 255, 255 }, { 200, 200, 200 },
                                { 100, 100, 100 }, { 0, 0, 0 } } }
    local cases = {
      { name = "striscia sul Game Boy", image = "strip.png", w = 160, h = 144, src = 144 },
      { name = "striscia in BIG", image = "strip.png", w = 320, h = 288, src = 144 },
      { name = "striscia in un pannello", image = "strip.png", w = 284, h = 244, src = 144 },
      { name = "striscia sulla tela alta del dex", image = "strip.png", w = 296, h = 576, src = 144 },
      { name = "mattonella sulla tela alta", image = "tile.png", w = 296, h = 576, src = 64 },
    }
    for _, c in ipairs(cases) do
      drawn = {}
      paint(paper, c.w, c.h, { image = c.image, speed = 0, still = true }, 0)
      local worst, bottom = 0, 0
      for _, d in ipairs(drawn) do
        worst = math.max(worst, d.scale)
        bottom = math.max(bottom, d.y + (d.rows or (c.src * d.scale)))
      end
      T.check(#drawn > 0, c.name .. ": qualcosa si disegna")
      T.check(worst <= 2,
        c.name .. ": non si ingrandisce oltre il doppio (x" .. worst .. ")")
      T.check(bottom >= c.h,
        ("%s: si arriva in fondo (%d di %d)"):format(c.name, bottom, c.h))
    end
    G.newImage, G.draw = realNew, realDraw
    Assets.image = realImage
  end
end

-- ------- UNOWN: la figura e' della LETTERA, non della specie (issue #7)
--
-- "gli unknown son tutti lettera A". Il record della specie porta la figura
-- della A; la lettera invece sta nel MON, impacchettata nei due bit centrali
-- dei suoi quattro DV. Una schermata che risolve l'arte dalla specie disegna
-- una box di ventisei A uguali, ed e' quello che vedeva chi torna dalle
-- Rovine di Alph.
do
  local okU, Unown = pcall(require, "src.core.gen2.Unown")
  if not (okU and type(Unown) == "table") then
    T.check(true, "engine senza modulo Unown: niente da verificare")
  else
    local Assets = require("src.render.Assets")
    local pokemon = Data.pokemon
    local hadDef = pokemon[Unown.SPECIES]
    -- una specie UNOWN di prova con tre forme, ognuna con la sua figura
    pokemon[Unown.SPECIES] = {
      id = Unown.SPECIES, name = "UNOWN", dex = 201,
      baseStats = { hp = 48, attack = 72, defense = 48, speed = 48, special = 72 },
      spriteFront = "unown_a.png",
      letters = {
        A = { spriteFront = "unown_a.png" },
        C = { spriteFront = "unown_c.png" },
        Z = { spriteFront = "unown_z.png" },
      },
    }
    local realImage = Assets.image
    local asked = {}
    Assets.image = function(path)
      asked[#asked + 1] = tostring(path)
      if tostring(path):find("^unown_") then
        return { _fake = true, getWidth = function() return 56 end,
                 getHeight = function() return 56 end }
      end
      return realImage(path)
    end

    -- un mon per lettera, con i DV che quella lettera vuole
    local function unownWithLetter(name)
      local want = Unown.index(name)
      for atk = 0, 15 do
        for def = 0, 15 do
          for spd = 0, 15 do
            for spc = 0, 15 do
              local dvs = { attack = atk, defense = def, speed = spd, special = spc }
              if Unown.letterFromDVs(dvs) == want then
                return { species = Unown.SPECIES, level = 5, dvs = dvs }
              end
            end
          end
        end
      end
      return nil
    end

    local g = fakeGame({})
    local s = factory.new(g)
    local seenPaths = {}
    for _, name in ipairs({ "A", "C", "Z" }) do
      local mon = unownWithLetter(name)
      T.check(mon ~= nil, "si trovano DV che scrivono la lettera " .. name)
      if mon then
        asked = {}
        -- attraverso il seam che il disegno usa davvero
        local chosen = s.spriteToDraw(mon)
        local img = chosen and chosen.img or nil
        local drew = asked[#asked]
        T.check(img ~= nil, "l'Unown " .. name .. " ha una figura")
        T.eq(drew, "unown_" .. name:lower() .. ".png",
          "e la figura chiesta e' quella della sua lettera")
        seenPaths[drew or "?"] = true
      end
    end
    local distinct = 0
    for _ in pairs(seenPaths) do distinct = distinct + 1 end
    T.eq(distinct, 3, "tre Unown diversi, tre figure diverse -- non tre A")

    Assets.image = realImage
    pokemon[Unown.SPECIES] = hadDef
  end
end

-- ------- LA POPPUP ESCE SOLO PER UNA FEATURE, O AL PRIMO AVVIO
--
-- Due casi e due soltanto: prima installazione, e un aggiornamento che
-- porta davvero la cosa di cui il pannello parla. Tutto il resto tace.
--
-- Il confronto e' PIU' VECCHIO-DI, non DIVERSO-DA. `~=` era il difetto: un
-- save che porta un timbro piu' NUOVO della build che sta girando --
-- qualcuno che ha provato una prerelease ed e' tornato alla stabile --
-- e' diverso da NEWS_VERSION, quindi il pannello si apriva e annunciava
-- feature che quella build NON ha.
do
  local game = fakeGame({ mon("FIXMON_A", 5) })
  local screen = factory.new(game)
  local older = screen.newsOlderThan
  local V = screen.newsVersion

  T.check(older(nil, V), "prima installazione: nessun timbro, si apre")
  T.check(older("", V), "e un timbro vuoto conta come nessun timbro")
  T.check(not older(V, V), "chi l'ha gia' vista non la rivede")

  -- il caso che questa release esiste per sistemare
  T.check(not older("99.0.0", V),
    "un timbro piu' nuovo della build NON riapre il pannello")

  T.check(older("1.20.0", V), "un aggiornamento che porta la feature la mostra")
  T.check(not older("1.21.0", "1.21.0"),
    "e un bugfix, che non tocca NEWS_VERSION, non la mostra")

  -- una prerelease confronta sui numeri di rilascio, non sulla coda
  T.check(older("1.20.0-beta.1", "1.21.0"),
    "una prerelease piu' vecchia si aggiorna comunque")

  -- e la regola che tiene tutto in piedi: NEWS_VERSION non e' la versione
  -- del manifest, o ogni bugfix interromperebbe chi gioca
  local manifest = io.open(DIR .. "/manifest.json")
  local blob = manifest:read("*a"); manifest:close()
  local shipped = blob:match('"version"%s*:%s*"([^"]+)"')
  T.check(shipped and shipped ~= V,
    "NEWS_VERSION non e' incollata alla versione del manifest (" ..
    tostring(shipped) .. " vs " .. tostring(V) .. ")")
end

-- ------- IN FULL SCREEN I POKEMON HANNO ANCORA I LORO COLORI
--
-- Una zona di palette e' indirizzata in TILE, quindi il passaggio si
-- rifiuta di emetterne UNA SOLA se cell, gridX, gridY, partyX o partyY non
-- sono multipli di 8 -- un'origine fuori dalla griglia colorerebbe un
-- rettangolo disallineato rispetto alla figura che contiene.
--
-- `gridY` era 20 e `gridX` portava un `+ 6`: nessuno dei due e' mai stato
-- multiplo di 8, quindi il pieno schermo falliva SEMPRE quel test. Niente
-- zone, e `remapOff` falso di conseguenza, cioe' `species = nil` dentro
-- paintPic: ogni battle pic sulla superficie piu' grande che il mod offre
-- veniva disegnata in quattro grigi DMG. Gli sprite overworld lo
-- nascondevano, perche' sono arte a colori propria e una zona non l'hanno
-- mai voluta.
--
-- Il controllo e' sull'INVARIANTE, non sul numero: qualsiasi origine
-- futura va bene purche' cada sulla griglia dei tile.
do
  local optStore = run.loader.modOptions.gen3_box
  local hadFull, hadGrid = optStore.fullscreen, optStore.grid
  optStore.fullscreen = true
  -- GRID BIG, cioe' cella 56. Con CLASSIC la cella e' 28, che NON e' un
  -- multiplo di 8, e rinunciare alle zone li' e' voluto da sempre -- PLAN.md
  -- lo dice: "una cella da 28 pixel e' tre tile e mezzo". Il caso che questa
  -- release ripara e' l'altro: cella allineata, origini che non lo erano.
  optStore.grid = "big"

  local G = love.graphics
  local realDim = G.getDimensions
  G.getDimensions = function() return 405, 900 end

  local game = fakeGame({ mon("FIXMON_A", 5) })
  local screen = factory.new(game)
  local L = screen.layoutOf and screen.layoutOf(game) or nil

  if L and L.full then
    for _, k in ipairs({ "cell", "gridX", "gridY", "partyX", "partyY" }) do
      T.eq(L[k] % 8, 0,
        "in pieno schermo " .. k .. " cade sulla griglia dei tile")
    end
  end

  local zones = screen:sgbPalettes(game)
  T.check(zones ~= nil,
    "il pieno schermo emette zone di palette invece di rinunciarci")

  G.getDimensions = realDim
  optStore.fullscreen, optStore.grid = hadFull, hadGrid
end

-- ------- SU GOLD IL PIENO SCHERMO RIEMPIE, NON STA IN MEZZO AL BIANCO
--
-- Su Gen 1 il layout pieno passa da uiSize() e il renderer lo adatta alla
-- finestra. Su Gold il mod si disegna da solo (drawWidescreen) e scalava
-- con `math.floor` del rapporto: fullLayout risponde con un numero INTERO
-- di pannelli -- su una finestra da 405 restituisce 296 -- quindi il
-- rapporto 1.37 finiva a 1 e Gold disegnava a grandezza naturale in mezzo
-- allo schermo, con una banda bianca per lato. Stessa opzione, stesso
-- layout, due immagini diverse.
--
-- Il floor resta giusto per BIG, che e' 320x288 fisso e vuole pixel interi.
do
  local optStore = run.loader.modOptions.gen3_box
  local hadFull, hadGrid = optStore.fullscreen, optStore.grid
  optStore.fullscreen = true
  optStore.grid = "big"

  local G = love.graphics
  local realDim, realScale, realPush, realPop = G.getDimensions, G.scale, G.push, G.pop
  G.getDimensions = function() return 405, 900 end

  local game = fakeGame({ mon("FIXMON_A", 5) })
  local screen = factory.new(game)

  local scales = {}
  G.scale = function(sx, sy) scales[#scales + 1] = sx; return realScale(sx, sy) end
  pcall(function() screen:drawWidescreen(405, 900) end)
  G.scale = realScale

  T.check(#scales > 0, "drawWidescreen scala la superficie")
  if #scales > 0 then
    local s = scales[1]
    T.check(s > 1,
      "e la scala riempie invece di fermarsi a 1 (era " .. tostring(s) .. ")")
    -- riempie almeno una delle due dimensioni, a meno di un pixel
    local L = screen.layoutOf and screen.layoutOf(game)
    if L then
      local fillsW = math.abs(L.w * s - 405) < 1
      local fillsH = math.abs(L.h * s - 900) < 1
      T.check(fillsW or fillsH,
        "e tocca almeno un bordo della finestra")
    end
  end

  G.getDimensions, G.push, G.pop = realDim, realPush, realPop
  optStore.fullscreen, optStore.grid = hadFull, hadGrid
end

T.finish("gen3_box")
