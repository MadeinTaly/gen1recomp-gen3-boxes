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
      local zones = {
        PaletteFX.zone(PaletteFX.GRAYS, 0, 0, L.w / 8 - 1, L.h / 8 - 1),
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

    local function fit(text)
      text = tostring(text or "")
      while #text > 1 and Font.width(text) > textMax() do
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
        outline(x, y, layout().cell, layout().cell)
        love.graphics.setColor(1, 1, 1, 1)
        if mon then drawPic(mon, x, y) end
        love.graphics.setColor(0, 0, 0, 1)
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
      do
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
      Font.draw(fit(line), TEXT_X, footerY())
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
