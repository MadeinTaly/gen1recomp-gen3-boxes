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
  local Assets = require("src.render.Assets")
  local Screens = require("src.ui.Screens")
  local Strings = require("src.core.Strings")
  local Stats = require("src.pokemon.Stats")
  local Sound = require("src.core.Sound")

  local SCREEN = "Gen3Box"

  -- Only what is actually honoured below. The vanilla box PC is left in
  -- place whichever way this is set: nothing is taken away, and turning the
  -- mod off leaves a save reaching its storage exactly as before.
  mod.options:define({
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
    -- See "the two layouts" above. CLASSIC is what 1.4.0 drew.
    { key = "grid", label = "GRID", type = "choice", default = "classic",
      choices = {
        { "CLASSIC", "classic" },
        { "BIG", "big" },
      } },
    -- See "the cry on put-down" (PLAN.md "5. THE CRY ON PUT-DOWN"). On by
    -- default: it changes nothing but sound, which is the line BOX HEALS
    -- is on the wrong side of.
    { key = "placeCry", label = "PLACE CRY", type = "toggle", default = true },
  })

  local function layout()
    local ok, value = pcall(function() return mod.options:get("grid") end)
    return LAYOUT[(ok and value) or "classic"] or LAYOUT.classic
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
    { id = "PLAIN",   pattern = "PLAIN",   palette = nil },
    { id = "STRIPES", pattern = "STRIPES",
      palette = { { 216, 224, 255 }, { 144, 168, 232 }, { 64, 88, 168 }, { 8, 16, 72 } } },
    { id = "CHECKS",  pattern = "CHECKS",
      palette = { { 224, 255, 224 }, { 152, 224, 152 }, { 64, 160, 64 }, { 8, 72, 8 } } },
    { id = "DOTS",    pattern = "DOTS",
      palette = { { 255, 224, 232 }, { 232, 152, 176 }, { 176, 64, 96 }, { 72, 8, 24 } } },
    { id = "WAVES",   pattern = "WAVES",
      palette = { { 216, 255, 255 }, { 136, 216, 224 }, { 40, 144, 160 }, { 8, 56, 64 } } },
    { id = "NIGHT",   pattern = "PLAIN",
      palette = { { 0, 0, 0 }, { 64, 64, 64 }, { 160, 160, 160 }, { 255, 255, 255 } } },
  }
  local WALLPAPER_BY_ID = {}
  for _, w in ipairs(WALLPAPERS) do WALLPAPER_BY_ID[w.id] = w end

  -- boxPapers, the same string-key-tolerant shape as boxNames above.
  local function paperIdOf(n)
    local papers = mod.save:get("boxPapers")
    local id = papers and (papers[n] or papers[tostring(n)])
    return (type(id) == "string" and WALLPAPER_BY_ID[id]) and id or "PLAIN"
  end

  local function paperOf(n)
    return WALLPAPER_BY_ID[paperIdOf(n)] or WALLPAPER_BY_ID.PLAIN
  end

  local function picOf(game, mon)
    local def = defOf(game, mon)
    local path = def and def.spriteFront
    if not path then return nil end
    -- Assets.image is the engine's cache, and it is also the seam a sprite
    -- mod shadows: going through it means a Crystal-sprites mod's art shows
    -- up in this grid too, rather than this screen pinning the vanilla PNG.
    local ok, img = pcall(Assets.image, path)
    if ok then return img end
    return nil
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

  -- ------- the screen

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
      markWindow = nil,  -- { mon = ..., cursor = 1 } while the window is open
    }

    -- ------- the surface this screen wants
    --
    -- Game:draw asks the TOP state for its size before anything is drawn,
    -- and passes 160x144 when the state has no opinion. So this is the
    -- whole mechanism: no enter hook, no restore on exit, and no way to
    -- leave the rest of the game wearing a canvas it did not ask for.
    function self:uiSize()
      local L = layout()
      return L.w, L.h
    end

    -- StateStack calls this on pop and only on pop -- a screen pushed ON TOP
    -- of this one (the summary) does not fire it -- so it is exactly "the
    -- player is done with the boxes" and nothing else.
    --
    -- Every box, not only the open one: a mon put away in box 3 an hour ago
    -- is as deposited as the one dropped a second ago, and "rested unless
    -- you happened to be looking at that box when you left" is not a rule
    -- anybody could hold in their head.
    function self:exit()
      if not healing() then return end
      for _, box in ipairs(Boxes.ensure(game.save)) do
        for _, mon in ipairs(box) do
          -- guard rather than trust: a mon that arrived from a save written
          -- by an older engine may be missing the fields heal writes
          pcall(Pokemon.heal, mon)
        end
      end
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
      table.remove(set, i)
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
        set[i] = held
        if self.mode == "party" then ensureStats(held) end
        playLandingCry(held)
        self.held = { mon = sitting, from = self.mode }
        return
      end
      if #set >= capacity() then
        say(self.mode == "box" and Strings("THE BOX IS FULL!")
                                or Strings("YOUR PARTY IS FULL!"))
        return
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
        a[#a + 1] = held
        if a == party then ensureStats(held) end
        playLandingCry(held)
        self.held = nil
        return true
      end
      if #b < bCap then
        b[#b + 1] = held
        if b == party then ensureStats(held) end
        playLandingCry(held)
        self.held = nil
        return true
      end
      say(Strings("NO ROOM ANYWHERE!"))
      return false
    end

    local function changeBox(step)
      if self.mode ~= "box" then return end
      local n = Boxes.COUNT
      game.save.currentBox = ((game.save.currentBox - 1 + step) % n) + 1
    end

    -- Walking off the left or right edge of a box steps to the next one, the
    -- way Ruby's L/R do -- a Game Boy has no shoulder buttons to spare, and
    -- this frees START to be a way out that always works. In the party pane
    -- there is nowhere to step to, so it wraps or clamps as before.
    local function move(dc, dr)
      local c, r = self.col + dc, self.row + dr
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
    local function showStats()
      local mon = self.held and self.held.mon or list()[index()]
      if mon then Screens.push(game, "SummaryMenu", mon) end
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
          game.save.currentBox = boxNum
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
      local L = layout()
      local k = L.cell / 28
      return 8 * k, 48 * k, 144 * k, 48 * k
    end

    local function openMarkWindowOnCursor()
      local mon = list()[index()]
      if not mon then return end
      self.markWindow = { mon = mon, cursor = 1 }
    end

    local function updateMarkWindow()
      local input = game.input
      local win = self.markWindow
      if input:wasPressed("left") then
        win.cursor = win.cursor > 1 and win.cursor - 1 or #MARK_ORDER
      elseif input:wasPressed("right") then
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
          game.save.currentBox = item.value
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

    -- WALLPAPER: a ListMenu of the named wallpapers above, each a pattern
    -- and a palette together. Choosing one writes boxPapers for THIS box
    -- only -- every other box keeps its own.
    local function openWallpaperMenu(parent)
      local n = game.save.currentBox
      local items = {}
      for _, w in ipairs(WALLPAPERS) do
        table.insert(items, { label = Strings(w.id), value = w.id })
      end
      local sub
      sub = mod.ui.ListMenu.new(game, Strings("WALLPAPER"), items, {
        kind = "gen3_box_wallpaper",
        onChoose = function(item)
          local papers = mod.save:get("boxPapers")
          if not papers then
            papers = {}
            mod.save:set("boxPapers", papers)
          end
          papers[n] = item.value
          papers[tostring(n)] = nil
          self.header = false
          say(Strings("WALLPAPER SET."))
          sub:close()
          parent:close()
        end,
      })
      game.stack:push(sub)
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
      if input:wasPressed("down") then
        self.header = false
      elseif input:wasPressed("left") then
        changeBox(-1)
      elseif input:wasPressed("right") then
        changeBox(1)
      elseif input:wasPressed("up") then
        -- the deliberate change PLAN.md calls out: wrap no longer takes UP
        -- from the top row straight to the bottom -- it stops here first,
        -- and UP again is what wraps
        if mod.options:get("wrap") then
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
        if self.mode == "box" and self.row == 0 then
          self.header = true
        else
          move(0, -1)
        end
      elseif input:wasPressed("down") then move(0, 1)
      elseif input:wasPressed("left") then move(-1, 0)
      elseif input:wasPressed("right") then move(1, 0)
      elseif input:wasPressed("a") then
        if self.held then
          place()
        elseif self.markMode then
          openMarkWindowOnCursor()
        else
          grab()
        end
      elseif input:wasPressed("select") then switchMode()
      elseif input:wasPressed("start") then
        -- START is the summary. It can be, because B below always means
        -- back: there is no cell where the way out disappears, which is
        -- what forced the earlier arrangement into putting STATS on B.
        showStats()
      elseif input:wasPressed("b") then
        back()
      end
    end

    -- ------- drawing

    local function cellRect(i0, mode)
      local L = layout()
      mode = mode or self.mode
      local n = mode == "box" and COLS or PARTY_COLS
      local c, r = i0 % n, math.floor(i0 / n)
      if mode == "box" then
        return L.gridX + c * L.cell, L.gridY + r * L.cell
      end
      return L.partyX + c * L.cell, L.partyY + r * L.cell
    end

    -- The scale is derived from the picture the game actually handed us,
    -- never assumed. Pics reach this screen through Assets.image, which is
    -- the seam a sprite mod shadows -- the README calls that a feature --
    -- so a 112x112 or 168x168 replacement is a thing that will happen, and
    -- a fixed 0.5/1.0 would have drawn it straight over its neighbours: a
    -- 2x pic overflows a BIG cell by a whole cell, a 3x one by two.
    --
    -- Integer factors both ways. Two-bit pixel art survives being halved
    -- or doubled and smears at 0.6, so this picks the nearest whole step
    -- that fits rather than the one that fills the cell exactly.
    local function picScale(img, cell)
      local m = math.max(img:getWidth(), img:getHeight())
      if m <= 0 then return 1 end
      if m <= cell then return math.max(1, math.floor(cell / m)) end
      return 1 / math.ceil(m / cell)
    end

    local function drawPic(mon, x, y)
      local img = picOf(game, mon)
      if not img then return end
      local L = layout()
      local k = picScale(img, L.cell)
      local w, h = img:getWidth() * k, img:getHeight() * k
      love.graphics.draw(img, x + (L.cell - w) / 2, y + (L.cell - h) / 2,
        0, k, k)
    end

    -- exposed so the suite can check the arithmetic without a graphics
    -- context, which is where the overflow above was found
    self.picScale = picScale

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
        love.graphics.polygon("fill", cx, cy - size / 2,
          cx - size / 2, cy + size / 2, cx + size / 2, cy + size / 2)
      elseif name == "HEART" then
        local r = size / 4
        love.graphics.circle("fill", cx - r, cy - r, r)
        love.graphics.circle("fill", cx + r, cy - r, r)
        love.graphics.polygon("fill", cx - size / 2, cy - r,
          cx + size / 2, cy - r, cx, cy + size / 2)
      end
    end

    local function drawMarks(mon, x, y)
      if not anyMarks(mon) then return end
      local cell = layout().cell
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
    function self:sgbPalettes(game)
      local L = layout()
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
      local paper = self.mode == "box" and paperOf(game.save.currentBox) or nil
      local baseColors = (paper and paper.palette) or PaletteFX.GRAYS
      local zones = {
        PaletteFX.zone(baseColors, 0, 0, L.w / 8 - 1, L.h / 8 - 1),
      }

      local function add(set, mode)
        for i, mon in ipairs(set) do
          local colors = PaletteFX.monPal(game.data, mon.species)
          if colors then
            local x, y = cellRect(i - 1, mode)
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
      if self.mode == "box" then
        add(boxList(game), "box")
      else
        add(game.save.party, "party")
      end
      -- the one on the cursor is drawn where the cursor is, so it needs its
      -- own zone or it wears whatever the cell under it is wearing
      if self.held and self.held.mon then
        local colors = PaletteFX.monPal(game.data, self.held.mon.species)
        if colors then
          local x, y = cellRect(self.row * cols() + self.col)
          local tx, ty = x / 8, y / 8
          zones[#zones + 1] =
            PaletteFX.zone(colors, tx, ty, tx + tiles - 1, ty + tiles - 1)
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
    local function textMax() return layout().w - TEXT_X * 2 end
    local function footerY() return layout().h - 12 end

    local function fitTo(text, maxW)
      text = tostring(text or "")
      while #text > 1 and Font.width(text) > maxW do
        text = text:sub(1, #text - 1)
      end
      return text
    end

    local function fit(text) return fitTo(text, textMax()) end

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
      local rowY = y + 4
      for i, name in ipairs(MARK_ORDER) do
        local text = fitTo((getMark(win.mon, name) and "*" or " ") .. Strings(name),
          w - 16)
        Font.draw(text, x + 8, rowY)
        if i == win.cursor then
          outline(x + 4, rowY - 1, Font.width(text) + 6, 10)
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
    local function drawWallpaperPattern(pattern, x, y, w, h)
      if pattern == "PLAIN" then return end
      love.graphics.setScissor(x, y, w, h)
      love.graphics.setColor(0, 0, 0, 0.12)
      local step = 8
      if pattern == "STRIPES" then
        for dx = -h, w, step do
          love.graphics.line(x + dx, y, x + dx + h, y + h)
        end
      elseif pattern == "CHECKS" then
        for cy = 0, h - 1, step do
          for cx = 0, w - 1, step do
            if (math.floor(cx / step) + math.floor(cy / step)) % 2 == 0 then
              love.graphics.rectangle("fill", x + cx, y + cy, step, step)
            end
          end
        end
      elseif pattern == "DOTS" then
        for cy = step / 2, h, step do
          for cx = step / 2, w, step do
            love.graphics.circle("fill", x + cx, y + cy, 2)
          end
        end
      elseif pattern == "WAVES" then
        for cy = step / 2, h, step do
          local prevX, prevY
          for cx = 0, w, 4 do
            local wy = cy + 3 * math.sin(cx / 8)
            if prevX then love.graphics.line(x + prevX, y + prevY, x + cx, y + wy) end
            prevX, prevY = cx, wy
          end
        end
      end
      love.graphics.setColor(0, 0, 0, 1)
      love.graphics.setScissor()
    end

    function self:draw()
      love.graphics.clear(1, 1, 1, 1)
      love.graphics.setColor(0, 0, 0, 1)

      if self.mode == "box" then
        local L = layout()
        local paper = paperOf(game.save.currentBox)
        drawWallpaperPattern(paper.pattern, L.gridX, L.gridY,
          COLS * L.cell, ROWS * L.cell)
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
      local shownTitle = fit(title)
      Font.draw(shownTitle, TEXT_X, 2)

      -- the cursor's own row (PLAN.md "the control scheme"): an outline
      -- around the title, sized to the text rather than the surface, so it
      -- reads on CLASSIC and BIG alike and never runs wider than fit()
      -- already guaranteed the text itself does not.
      if onHeader then
        outline(TEXT_X - 2, 0, Font.width(shownTitle) + 4, 10)
      end

      for i0 = 0, total - 1 do
        local x, y = cellRect(i0)
        local mon = set[i0 + 1]
        love.graphics.setColor(0, 0, 0, 0.25)
        outline(x, y, layout().cell, layout().cell)
        love.graphics.setColor(1, 1, 1, 1)
        if mon then drawPic(mon, x, y) end
        love.graphics.setColor(0, 0, 0, 1)
        if mon then drawMarks(mon, x, y) end
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
      local cx, cy = cellRect(self.row * cols() + self.col)
      -- on the header the outline above is the cursor; the grid keeps none,
      -- so there is never more than one place on screen the cursor reads as
      -- being
      if not onHeader then
        local cell = layout().cell
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
          line = Strings("SEL:PARTY B:EXIT")
        else
          line = Strings("SEL:BOX B:EXIT")
        end
      end
      Font.draw(fit(line), TEXT_X, footerY())

      -- the marking window, last, so it sits over the grid and the cursor
      drawMarkWindow()
    end

    return self
  end

  mod.content.screens:register(SCREEN, { new = newScreen })

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
