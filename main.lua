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
local CELL = 28
local GRID_X, GRID_Y = 10, 16
local PARTY_COLS, PARTY_ROWS = 3, 2
local PARTY_X, PARTY_Y = 38, 40

return function(mod)
  local Boxes = require("src.pokemon.Boxes")
  local Party = require("src.pokemon.Party")
  local Font = require("src.render.Font")
  local Assets = require("src.render.Assets")
  local Screens = require("src.ui.Screens")
  local Strings = require("src.core.Strings")

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
  })

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
    }

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
        self.held = { mon = sitting, from = self.mode }
        return
      end
      if #set >= capacity() then
        say(self.mode == "box" and Strings("THE BOX IS FULL!")
                                or Strings("YOUR PARTY IS FULL!"))
        return
      end
      set[#set + 1] = held
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
      if #a < aCap then a[#a + 1] = held; self.held = nil; return true end
      if #b < bCap then b[#b + 1] = held; self.held = nil; return true end
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

    function self:update()
      local input = game.input
      if input:wasPressed("up") then move(0, -1)
      elseif input:wasPressed("down") then move(0, 1)
      elseif input:wasPressed("left") then move(-1, 0)
      elseif input:wasPressed("right") then move(1, 0)
      elseif input:wasPressed("a") then
        if self.held then place() else grab() end
      elseif input:wasPressed("select") then switchMode()
      elseif input:wasPressed("start") then
        -- START is the summary. It can be, because B below always means
        -- back: there is no cell where the way out disappears, which is
        -- what forced the earlier arrangement into putting STATS on B.
        showStats()
      elseif input:wasPressed("b") then
        -- B is back, and only back -- the convention every other screen in
        -- this game follows. Carrying one it goes back to a shelf first:
        -- a carried Pokémon is out of both arrays, so leaving with it in
        -- hand would drop it out of the save.
        if self.held then
          if stow() then say(Strings("PUT IT BACK.")) end
        else
          game.stack:pop()
        end
      end
    end

    -- ------- drawing

    local function cellRect(i0)
      local c, r = i0 % cols(), math.floor(i0 / cols())
      if self.mode == "box" then
        return GRID_X + c * CELL, GRID_Y + r * CELL
      end
      return PARTY_X + c * CELL, PARTY_Y + r * CELL
    end

    local function drawPic(mon, x, y)
      local img = picOf(game, mon)
      if not img then return end
      local w, h = img:getWidth(), img:getHeight()
      -- half scale: 56 -> 28 fills the cell, 40 -> 20 sits centred in it
      love.graphics.draw(img, x + (CELL - w / 2) / 2, y + (CELL - h / 2) / 2,
        0, 0.5, 0.5)
    end

    local function outline(x, y, w, h)
      love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
    end

    -- Every glyph in this font advances 8 pixels and the screen is 160
    -- wide, so a line beside a 4-pixel margin has room for nineteen of
    -- them and no more. 1.1.0 shipped a "SELECT:PARTY START:BOX" hint --
    -- twenty-two glyphs, 176 pixels -- and the tail simply ran off the
    -- right edge. Nothing is drawn now without being measured first.
    local TEXT_X = 4
    local TEXT_MAX = 160 - TEXT_X * 2

    local function fit(text)
      text = tostring(text or "")
      while #text > 1 and Font.width(text) > TEXT_MAX do
        text = text:sub(1, #text - 1)
      end
      return text
    end

    function self:draw()
      love.graphics.clear(1, 1, 1, 1)
      love.graphics.setColor(0, 0, 0, 1)

      local set = list()
      local total = cols() * rows()

      -- header: which box, how full, and which pane has the cursor
      local title
      if self.mode == "box" then
        title = Strings("BOX %d %d/%d", game.save.currentBox,
          #set, Boxes.CAPACITY)
      else
        title = Strings("PARTY %d/%d", #set, Party.MAX)
      end
      Font.draw(fit(title), TEXT_X, 2)

      for i0 = 0, total - 1 do
        local x, y = cellRect(i0)
        local mon = set[i0 + 1]
        love.graphics.setColor(0, 0, 0, 0.25)
        outline(x, y, CELL, CELL)
        love.graphics.setColor(1, 1, 1, 1)
        if mon then drawPic(mon, x, y) end
        love.graphics.setColor(0, 0, 0, 1)
      end

      -- cursor last, so it sits over the art it is pointing at
      local cx, cy = cellRect(self.row * cols() + self.col)
      love.graphics.setLineWidth(1)
      outline(cx - 1, cy - 1, CELL + 2, CELL + 2)

      -- the carried mon rides just above the cursor, clear of the grid
      if self.held then
        love.graphics.setColor(1, 1, 1, 1)
        drawPic(self.held.mon, cx, cy - 10)
        love.graphics.setColor(0, 0, 0, 1)
      end

      -- footer: the notice if one is fresh, else what the cursor is on
      local line
      if self.notice then
        local now = love.timer and love.timer.getTime() or 0
        if now - self.noticeAt < 1.5 then line = self.notice else self.notice = nil end
      end
      if not line then
        local mon = self.held and self.held.mon or set[index()]
        if mon then
          line = Strings("%s :L%d", nameOf(game, mon), mon.level or 0)
        elseif self.mode == "box" then
          line = Strings("SEL:PARTY B:EXIT")
        else
          line = Strings("SEL:BOX B:EXIT")
        end
      end
      Font.draw(fit(line), TEXT_X, 132)
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
